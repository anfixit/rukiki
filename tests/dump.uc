#!/usr/bin/ucode
// Выгружает собранный nikki-конфиг из тестового каталога в JSON.
// Порядок секций сохраняется (uci.foreach идёт по файлу).
'use strict';
import { cursor } from 'uci';

const dir = getenv('RUKIKI_UCI_DIR');
const savedir = getenv('RUKIKI_UCI_SAVEDIR');
const uci = dir ? cursor(dir, savedir || dir) : cursor();
uci.load('nikki');

const out = {
	rule: [], rule_provider: [], nameserver: [],
	subscription: uci.get_all('nikki', 'subscription') || {},
	mixin: uci.get_all('nikki', 'mixin') || {},
	proxy: uci.get_all('nikki', 'proxy') || {},
	config: uci.get_all('nikki', 'config') || {},
};
uci.foreach('nikki', 'rule', (s) => push(out.rule, s));
uci.foreach('nikki', 'rule_provider', (s) => push(out.rule_provider, s));
uci.foreach('nikki', 'nameserver', (s) => push(out.nameserver, s));

printf('%.J', out);
