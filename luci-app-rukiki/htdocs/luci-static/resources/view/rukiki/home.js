'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require poll';
'require ui';

const callStatus = rpc.declare({
	object: 'luci.rukiki', method: 'status', expect: { '': {} }
});
const callApply = rpc.declare({
	object: 'luci.rukiki', method: 'apply', expect: { '': {} }
});
const callCheck = rpc.declare({
	object: 'luci.rukiki', method: 'check_subscription', expect: { '': {} }
});
const callTest = rpc.declare({
	object: 'luci.rukiki', method: 'test_vpn', expect: { '': {} }
});
const callUpdate = rpc.declare({
	object: 'luci.rukiki', method: 'update_lists', expect: { '': {} }
});

const SERVICE_NAMES = {
	youtube: 'YouTube',
	discord: 'Discord',
	social: _('Соцсети'),
	ai: _('AI-сервисы'),
	media: _('Зарубежные медиа'),
	gaming: _('Игровые сервисы'),
};

function dash(v) {
	return (v == null || v === '') ? '—' : v;
}

function statusRow(label, value) {
	return E('div', { 'class': 'rukiki-status-row' }, [
		E('span', { 'style': 'color:#888' }, label),
		E('span', { 'style': 'font-weight:600' }, value),
	]);
}

function renderStatus(st) {
	const running = st.service_running === true;
	const badge = E('span', {
		'style': 'padding:2px 10px;border-radius:10px;color:#fff;background:'
			+ (running ? '#2ea043' : '#a0a0a0')
	}, running ? _('Работает') : _('Остановлен'));

	const sub = st.subscription_set
		? (st.subscription_state || _('задана'))
		: _('не задана');

	return E('div', {
		'style': 'display:grid;grid-template-columns:1fr 1fr;gap:6px 24px;'
			+ 'padding:12px 0;max-width:640px'
	}, [
		statusRow(_('Сервис'), badge),
		statusRow(_('Подписка'), dash(sub)),
		statusRow(_('Найдено нод'), dash(st.node_count)),
		statusRow(_('Текущая нода'), dash(st.current_node)),
		statusRow(_('Задержка'), dash(st.current_latency)),
		statusRow(_('Резерв'), dash(st.backup_state)),
		statusRow(_('Проверка'), dash(st.last_check)),
		statusRow(_('Списки обновлены'), dash(st.last_list_update)),
	]);
}

function notify(ok, okMsg, errMsg) {
	ui.addNotification(null,
		E('p', ok ? okMsg : errMsg),
		ok ? 'info' : 'warning');
}

return view.extend({
	load: function () {
		return Promise.all([uci.load('rukiki')]);
	},

	refreshStatus: function (container) {
		return callStatus().then((st) => {
			while (container.firstChild)
				container.removeChild(container.firstChild);
			container.appendChild(renderStatus(st || {}));
		});
	},

	render: function () {
		const self = this;
		let m, s, o;

		m = new form.Map('rukiki', _('Smart VPN'),
			_('Вставьте ссылку подписки и нажмите «Сохранить и запустить». '
			+ 'Остальное система настроит сама.'));

		// --- Подписка ---
		s = m.section(form.NamedSection, 'subscription', 'subscription',
			_('Подписка'));
		o = s.option(form.Value, 'url', _('Ссылка подписки'));
		o.rmempty = false;
		o.validate = function (section_id, value) {
			if (value === '' || /^https?:\/\//.test(value))
				return true;
			return _('Ссылка должна начинаться с http:// или https://');
		};
		o = s.option(form.Flag, 'auto_update', _('Автоматически обновлять'));
		o.default = '1';

		// --- Категории (service-наборы) ---
		s = m.section(form.GridSection, 'ruleset', _('Категории через VPN'));
		s.addremove = false;
		s.sortable = false;
		s.filter = function (section_id) {
			return uci.get('rukiki', section_id, 'role') == 'service';
		};
		o = s.option(form.DummyValue, '_name', _('Сервис'));
		o.cfgvalue = function (section_id) {
			return SERVICE_NAMES[section_id] || section_id;
		};
		o = s.option(form.Flag, 'enabled', _('Через VPN'));
		o.rmempty = false;

		// --- Дополнительно ---
		s = m.section(form.NamedSection, 'main', 'rukiki', _('Дополнительно'));
		o = s.option(form.ListValue, 'mode', _('Режим выбора сервера'));
		o.value('auto', _('Автоматически (лучший)'));
		o.value('manual', _('Вручную'));
		o.default = 'auto';
		o = s.option(form.Flag, 'auto_best_server',
			_('Авто-выбор лучшего сервера'));
		o = s.option(form.Flag, 'auto_failover',
			_('Авто-переключение при отказе'));
		o = s.option(form.Flag, 'bypass_blocks',
			_('Обходить блокировки и недоступные сервисы'));
		o = s.option(form.Flag, 'ru_direct',
			_('Российские сайты — напрямую'));
		o = s.option(form.Flag, 'auto_update_lists',
			_('Обновлять списки автоматически'));

		// --- Пользовательские правила ---
		s = m.section(form.GridSection, 'rule', _('Свои правила'),
			_('Имеют приоритет над автосписками и не сбрасываются '
			+ 'при обновлении.'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = false;
		o = s.option(form.Flag, 'enabled', _('Вкл'));
		o.default = '1';
		o = s.option(form.Value, 'domain', _('Домен'));
		o.placeholder = 'example.com';
		o.rmempty = false;
		o = s.option(form.ListValue, 'action', _('Куда'));
		o.value('vpn', _('Через VPN'));
		o.value('direct', _('Напрямую'));
		o.value('auto', _('Автоматически'));
		o.default = 'auto';

		return m.render().then(function (mapNode) {
			const statusBox = E('div', {});
			self.refreshStatus(statusBox);
			poll.add(function () {
				return self.refreshStatus(statusBox);
			}, 5);

			const btn = function (label, style, handler) {
				return E('button', {
					'class': 'btn cbi-button cbi-button-' + style,
					'style': 'margin-right:8px',
					'click': ui.createHandlerFn(self, handler),
				}, label);
			};

			const buttons = E('div', { 'style': 'margin:12px 0' }, [
				btn(_('Сохранить и запустить'), 'positive', function () {
					return m.save().then(callApply).then(function (r) {
						notify(r && r.success,
							_('Запущено'), _('Ошибка применения'));
						return self.refreshStatus(statusBox);
					});
				}),
				btn(_('Проверить подписку'), 'action', function () {
					return m.save().then(callCheck).then(function (r) {
						notify(r && r.success,
							_('Подписка валидна'), _('Подписка недоступна'));
					});
				}),
				btn(_('Обновить списки'), 'neutral', function () {
					return callUpdate().then(function (r) {
						notify(r && r.success,
							_('Списки обновляются'), _('Ошибка обновления'));
					});
				}),
				btn(_('Тест VPN'), 'neutral', function () {
					return callTest().then(function (r) {
						const ok = r && r.running;
						notify(ok, _('VPN отвечает'), _('VPN недоступен'));
					});
				}),
			]);

			const header = E('div', {}, [
				E('h3', {}, _('Состояние')),
				statusBox,
				buttons,
				E('hr', {}),
			]);
			mapNode.insertBefore(header, mapNode.firstChild);
			return mapNode;
		});
	},
});
