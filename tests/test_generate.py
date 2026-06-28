"""Проверки проекции rukiki -> nikki UCI + mixin.yaml."""

from conftest import requires_ucode


def _rule_str(rule: dict) -> str:
    parts = [rule.get('type', '')]
    if rule.get('matcher'):
        parts.append(rule['matcher'])
    parts.append(rule.get('node', ''))
    return ','.join(parts)


@requires_ucode
def test_terminal_rule_is_match_direct(projection):
    rules = projection['nikki']['rule']
    assert _rule_str(rules[-1]) == 'MATCH,DIRECT'


@requires_ucode
def test_user_rules_come_first(projection):
    rules = projection['nikki']['rule']
    assert _rule_str(rules[0]) == 'DOMAIN-SUFFIX,gosuslugi.ru,DIRECT'
    assert _rule_str(rules[1]) == 'DOMAIN-SUFFIX,youtube.com,PROXY'


@requires_ucode
def test_role_order(projection):
    rules = projection['nikki']['rule']
    order = [r.get('matcher') for r in rules if r.get('type') == 'RULE-SET']
    # allowlist < blocked < geoblock < service(youtube) < ru_ip
    assert order.index('allowlist') < order.index('blocked')
    assert order.index('blocked') < order.index('geoblock')
    assert order.index('geoblock') < order.index('youtube')
    assert order.index('youtube') < order.index('ru_ip')


@requires_ucode
def test_empty_url_ruleset_skipped(projection):
    nikki = projection['nikki']
    rule_matchers = [r.get('matcher') for r in nikki['rule']]
    provider_names = [p.get('name') for p in nikki['rule_provider']]
    assert 'media' not in rule_matchers
    assert 'media' not in provider_names


@requires_ucode
def test_allowlist_is_direct(projection):
    rules = projection['nikki']['rule']
    allow = next(r for r in rules if r.get('matcher') == 'allowlist')
    assert allow['node'] == 'DIRECT'


@requires_ucode
def test_providers_download_via_direct(projection):
    providers = projection['nikki']['rule_provider']
    assert providers
    assert all(p.get('node') == 'DIRECT' for p in providers)
    assert all(p.get('file_format') == 'mrs' for p in providers)


@requires_ucode
def test_proxy_groups_shape(projection):
    groups = projection['mixin']['nikki-proxy-groups']
    by_name = {g['name']: g for g in groups}
    assert set(by_name) == {'PROXY', 'AUTO', 'MANUAL'}
    assert by_name['AUTO']['type'] == 'url-test'
    assert by_name['AUTO']['include-all'] is True
    assert by_name['MANUAL']['include-all'] is True
    assert 'DIRECT' in by_name['MANUAL']['proxies']
    assert by_name['PROXY']['proxies'][0] == 'AUTO'


@requires_ucode
def test_mixin_file_merge_enabled(projection):
    assert projection['nikki']['mixin'].get('mixin_file_content') == '1'
    assert projection['nikki']['mixin'].get('rule') == '1'
    assert projection['nikki']['mixin'].get('rule_provider') == '1'


@requires_ucode
def test_secret_not_leaked_into_mixin(projection):
    assert 'SECRET123' not in projection['mixin_text']


@requires_ucode
def test_api_localhost_when_wan_disabled(projection):
    assert projection['nikki']['mixin'].get('api_listen') == '127.0.0.1:9090'
