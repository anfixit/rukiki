#!/usr/bin/ucode
// /etc/rukiki/ucode/generate.uc
//
// Генератор простого режима rukiki.
// Читает UCI 'rukiki' (намерение) и проецирует его в:
//   * UCI 'nikki'           — subscription / proxy / mixin-флаги /
//                             @rule[] / @rule_provider[] /
//                             nameserver[] / nameserver_policy[];
//   * /etc/nikki/mixin.yaml — proxy-groups PROXY / AUTO / MANUAL.
//
// Идемпотентен: свои namespace в 'nikki' полностью пересобирает.
// Ничего не перезапускает — reload делает apply-обёртка.
// В stdout ничего секретного не печатает (url подписки — секрет).

'use strict';

import { cursor } from 'uci';
import { writefile } from 'fs';

const MIXIN_FILE = getenv('RUKIKI_MIXIN_FILE') || '/etc/nikki/mixin.yaml';

const HEALTH_CHECK_URL = 'https://cp.cloudflare.com/generate_204';
const HEALTH_CHECK_INTERVAL = 300;
const URL_TEST_TOLERANCE = 50;
const RULE_FILE_SIZE_LIMIT = 20000000;
const FAKE_IP_RANGE = '198.18.0.1/16';

// Локальные сети -> DIRECT (инвариант, без внешних зависимостей).
const LOCAL_CIDR4 = [
	'127.0.0.0/8', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16',
	'169.254.0.0/16', '100.64.0.0/10', '224.0.0.0/4', '240.0.0.0/4',
];
const LOCAL_CIDR6 = ['::1/128', 'fc00::/7', 'fe80::/10'];

// Фильтр fake-ip: локальные имена и connectivity-check мимо fake-ip.
const FAKE_IP_FILTER = [
	'+.lan', '+.local', '+.localhost',
	'time.*.com', 'ntp.*.com', '+.msftconnecttest.com',
];

// Порядок ролей наборов в итоговых правилах (меньше — раньше).
const ROLE_RANK = {
	allowlist: 1,
	blocked: 2,
	geoblock: 3,
	service: 4,
	ru_ip: 5,
};


function uci_bool(value) {
	return value == '1' || value == 'true' || value === true;
}


function read_main(uci) {
	return {
		enabled: uci_bool(uci.get('rukiki', 'main', 'enabled')),
		mode: uci.get('rukiki', 'main', 'mode') || 'auto',
		auto_failover: uci_bool(uci.get('rukiki', 'main', 'auto_failover')),
		bypass_blocks: uci_bool(uci.get('rukiki', 'main', 'bypass_blocks')),
		ru_direct: uci_bool(uci.get('rukiki', 'main', 'ru_direct')),
	};
}


// Роль набора активна, если включён сам набор И соответствующий тумблер.
function role_enabled(role, main) {
	if (role == 'allowlist' || role == 'ru_ip')
		return main.ru_direct;
	if (role == 'blocked' || role == 'geoblock')
		return main.bypass_blocks;
	return true;
}


// --- Сборка proxy-groups (в mixin.yaml) -----------------------

function build_proxy_groups(main) {
	const order = (main.mode == 'manual')
		? ['MANUAL', 'AUTO', 'DIRECT']
		: ['AUTO', 'MANUAL', 'DIRECT'];

	const auto = {
		name: 'AUTO',
		type: 'url-test',
		'include-all': true,
		url: HEALTH_CHECK_URL,
		interval: HEALTH_CHECK_INTERVAL,
		tolerance: URL_TEST_TOLERANCE,
	};
	const manual = {
		name: 'MANUAL',
		type: 'select',
		'include-all': true,
		proxies: ['DIRECT'],
	};
	const proxy = {
		name: 'PROXY',
		type: 'select',
		proxies: order,
	};
	return [proxy, auto, manual];
}


function write_mixin_yaml(groups) {
	// JSON валиден как YAML, который читает yq в init-скрипте Nikki.
	const payload = { 'nikki-proxy-groups': groups };
	writefile(MIXIN_FILE, sprintf('%.J\n', payload));
}


// --- Очистка наших namespace в nikki --------------------------

function clear_sections(uci, type) {
	const names = [];
	uci.foreach('nikki', type, (s) => { push(names, s['.name']); });
	for (let name in names)
		uci.delete('nikki', name);
}


// --- Правила и провайдеры -------------------------------------

function collect_user_rules(uci) {
	const direct = [];
	const vpn = [];
	uci.foreach('rukiki', 'rule', (s) => {
		if (!uci_bool(s.enabled) || !s.domain)
			return;
		if (s.action == 'direct')
			push(direct, s.domain);
		else if (s.action == 'vpn')
			push(vpn, s.domain);
		// action == 'auto' -> правило не создаётся (решают списки)
	});
	return { direct, vpn };
}


function collect_rulesets(uci, main) {
	const sets = [];
	uci.foreach('rukiki', 'ruleset', (s) => {
		const role = s.role;
		if (!uci_bool(s.enabled) || !role_enabled(role, main))
			return;
		if (!s.url) {
			// URL ещё не опубликован агрегатором — пропускаем,
			// чтобы не ломать конфиг. Подписка работает и без набора.
			warn(`rukiki: ruleset '${s['.name']}' has empty url, skipped\n`);
			return;
		}
		push(sets, {
			name: s['.name'],
			role: role,
			behavior: s.behavior || 'domain',
			action: s.action || 'proxy',
			url: s.url,
			interval: s.interval || '86400',
		});
	});
	// Стабильный порядок по роли; внутри роли — порядок UCI.
	return sort(sets, (a, b) => ROLE_RANK[a.role] - ROLE_RANK[b.role]);
}


// Возвращает массив rule-спеков {type, matcher, node, no_resolve}
// в финальном порядке. MATCH,DIRECT — терминальный.
function build_rules(user, rulesets) {
	const rules = [];
	const add = (type, matcher, node, no_resolve) =>
		push(rules, { type, matcher, node, no_resolve: !!no_resolve });

	// 1-2. Пользовательские правила (высший приоритет).
	for (let d in user.direct)
		add('DOMAIN-SUFFIX', d, 'DIRECT', false);
	for (let d in user.vpn)
		add('DOMAIN-SUFFIX', d, 'PROXY', false);

	// 3. Локальные сети -> DIRECT.
	for (let cidr in LOCAL_CIDR4)
		add('IP-CIDR', cidr, 'DIRECT', true);
	for (let cidr in LOCAL_CIDR6)
		add('IP-CIDR6', cidr, 'DIRECT', true);
	add('DOMAIN-SUFFIX', 'lan', 'DIRECT', false);
	add('DOMAIN-SUFFIX', 'local', 'DIRECT', false);

	// 4-8. Наборы по ролям.
	for (let rs in rulesets) {
		const node = (rs.action == 'direct') ? 'DIRECT' : 'PROXY';
		const no_resolve = (rs.behavior == 'ipcidr');
		add('RULE-SET', rs.name, node, no_resolve);
	}

	// 9. Финальное правило.
	add('MATCH', '', 'DIRECT', false);
	return rules;
}


// --- Запись в UCI nikki ---------------------------------------

function write_rule_providers(uci, rulesets) {
	for (let rs in rulesets) {
		const id = uci.add('nikki', 'rule_provider');
		uci.set('nikki', id, 'enabled', '1');
		uci.set('nikki', id, 'rukiki', '1');
		uci.set('nikki', id, 'name', rs.name);
		uci.set('nikki', id, 'type', 'http');
		uci.set('nikki', id, 'url', rs.url);
		uci.set('nikki', id, 'node', 'DIRECT');
		uci.set('nikki', id, 'file_format', 'mrs');
		uci.set('nikki', id, 'behavior', rs.behavior);
		uci.set('nikki', id, 'update_interval', rs.interval);
		uci.set('nikki', id, 'file_size_limit', `${RULE_FILE_SIZE_LIMIT}`);
	}
}


function write_rules(uci, rules) {
	for (let r in rules) {
		const id = uci.add('nikki', 'rule');
		uci.set('nikki', id, 'enabled', '1');
		uci.set('nikki', id, 'rukiki', '1');
		uci.set('nikki', id, 'type', r.type);
		if (r.matcher != '')
			uci.set('nikki', id, 'matcher', r.matcher);
		uci.set('nikki', id, 'node', r.node);
		if (r.no_resolve)
			uci.set('nikki', id, 'no_resolve', '1');
	}
}


function write_dns(uci) {
	const bootstrap = uci.get('rukiki', 'dns', 'bootstrap') || [];
	const direct_resolver = uci.get('rukiki', 'dns', 'direct_resolver');
	const proxy_resolver = uci.get('rukiki', 'dns', 'proxy_resolver');
	const ipv6 = uci_bool(uci.get('rukiki', 'dns', 'ipv6'));

	const add_ns = (type, servers) => {
		const id = uci.add('nikki', 'nameserver');
		uci.set('nikki', id, 'enabled', '1');
		uci.set('nikki', id, 'rukiki', '1');
		uci.set('nikki', id, 'type', type);
		uci.set('nikki', id, 'nameserver', servers);
	};

	// default-nameserver резолвит хосты DoH-серверов без цикла.
	add_ns('default-nameserver', bootstrap);
	add_ns('nameserver', [direct_resolver]);
	add_ns('direct-nameserver', [direct_resolver]);
	add_ns('proxy-server-nameserver', [proxy_resolver]);

	// mixin-флаги DNS/fake-ip.
	uci.set('nikki', 'mixin', 'dns_enabled', '1');
	uci.set('nikki', 'mixin', 'dns_mode', 'fake-ip');
	uci.set('nikki', 'mixin', 'fake_ip_range', FAKE_IP_RANGE);
	uci.set('nikki', 'mixin', 'fake_ip_filter', '1');
	uci.set('nikki', 'mixin', 'fake_ip_filters', FAKE_IP_FILTER);
	uci.set('nikki', 'mixin', 'dns_nameserver', '1');
	// respect-rules: DNS следует за маршрутизацией (direct vs proxy).
	uci.set('nikki', 'mixin', 'dns_respect_rules', '1');
	uci.set('nikki', 'mixin', 'dns_ipv6', ipv6 ? '1' : '0');
	uci.set('nikki', 'mixin', 'ipv6', ipv6 ? '1' : '0');
}


function write_subscription(uci) {
	const url = uci.get('rukiki', 'subscription', 'url') || '';
	const ua = uci.get('rukiki', 'subscription', 'user_agent') || 'clash.meta';
	uci.set('nikki', 'subscription', 'name', 'rukiki');
	uci.set('nikki', 'subscription', 'url', url);
	uci.set('nikki', 'subscription', 'user_agent', ua);
	uci.set('nikki', 'subscription', 'prefer', 'remote');
}


function write_app_and_proxy(uci, main) {
	const ipv6 = uci_bool(uci.get('rukiki', 'dns', 'ipv6'));
	const yacd_wan = uci_bool(uci.get('rukiki', 'security', 'yacd_wan_access'));

	uci.set('nikki', 'config', 'profile', 'subscription:subscription');
	uci.set('nikki', 'config', 'enabled', main.enabled ? '1' : '0');

	uci.set('nikki', 'proxy', 'enabled', '1');
	uci.set('nikki', 'proxy', 'tcp_mode', 'tproxy');
	uci.set('nikki', 'proxy', 'udp_mode', 'tproxy');
	uci.set('nikki', 'proxy', 'ipv4_dns_hijack', '1');
	uci.set('nikki', 'proxy', 'ipv6_dns_hijack', ipv6 ? '1' : '0');
	uci.set('nikki', 'proxy', 'ipv4_proxy', '1');
	uci.set('nikki', 'proxy', 'ipv6_proxy', ipv6 ? '1' : '0');

	// API/дашборд только на localhost, если WAN-доступ выключен.
	uci.set('nikki', 'mixin', 'api_listen',
		yacd_wan ? '[::]:9090' : '127.0.0.1:9090');

	// Включаем подмешивание наших правил/провайдеров/файла.
	uci.set('nikki', 'mixin', 'rule', '1');
	uci.set('nikki', 'mixin', 'rule_provider', '1');
	uci.set('nikki', 'mixin', 'mixin_file_content', '1');
}


function main() {
	const test_dir = getenv('RUKIKI_UCI_DIR');
	const uci = test_dir ? cursor(test_dir, test_dir) : cursor();
	uci.load('rukiki');
	uci.load('nikki');

	const cfg = read_main(uci);

	// 1. proxy-groups -> файл.
	write_mixin_yaml(build_proxy_groups(cfg));

	// 2. Очищаем свои namespace в nikki (идемпотентность).
	clear_sections(uci, 'rule');
	clear_sections(uci, 'rule_provider');
	clear_sections(uci, 'nameserver');
	clear_sections(uci, 'nameserver_policy');

	// 3. Пересобираем.
	const rulesets = collect_rulesets(uci, cfg);
	const user_rules = collect_user_rules(uci);

	write_subscription(uci);
	write_dns(uci);
	write_rule_providers(uci, rulesets);
	write_rules(uci, build_rules(user_rules, rulesets));
	write_app_and_proxy(uci, cfg);

	uci.commit('nikki');
}

main();
