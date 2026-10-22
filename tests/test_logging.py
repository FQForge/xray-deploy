"""Run with python3 -B -m unittest discover -s tests -v; no live services are used."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / 'xray-ss.sh'
MOCK_SERVICES = r'''
INIT_SYSTEM="$XSS_INIT_SYSTEM"
require_root() { :; }
service_is_active() { [[ -f "$ETC_DIR/active" ]]; }
service_restart() {
  printf 'restart\n' >> "$ETC_DIR/events"
  if [[ -f "$ETC_DIR/fail-restart" ]]; then rm "$ETC_DIR/fail-restart"; return 1; fi
  if [[ -f "$ETC_DIR/fail-status" ]]; then
    rm "$ETC_DIR/fail-status" "$ETC_DIR/active"; return 0
  fi
  touch "$ETC_DIR/active"
}
service_daemon_reload() {
  if [[ -f "$ETC_DIR/fail-reload" ]]; then rm "$ETC_DIR/fail-reload"; return 1; fi
}
'''


class LoggingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='xray-logging-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, XSS_ETC_DIR=str(self.root / 'etc'),
                        XSS_OPT_DIR=str(self.root / 'opt'), XSS_ENTRY=str(self.root / 'bin/xnode'),
                        XSS_CORE_LINK=str(self.root / 'bin/core'), XSS_INIT_SYSTEM='manual',
                        XSS_LOG_FILE=str(self.root / 'log/xray.log'), XSS_PID_FILE=str(self.root / 'run/pid'),
                        XSS_UNIT_FILE=str(self.root / 'units/xray-ss.service'),
                        XSS_OPENRC_UNIT_FILE=str(self.root / 'init/openrc'),
                        XSS_SYSV_UNIT_FILE=str(self.root / 'init/sysv'),
                        XSS_PROCD_UNIT_FILE=str(self.root / 'init/procd'),
                        XSS_RUNIT_SERVICE_DIR=str(self.root / 'sv/xray-ss'), XSS_SKIP_DEP_INSTALL='1')
        self.shell('init_config\ninstall_service_unit')
        self.config_path = self.root / 'etc/config.json'
        self.log = Path(self.env['XSS_LOG_FILE'])
        core = Path(self.env['XSS_CORE_LINK'])
        core.write_text('#!/bin/sh\ntouch "$XSS_ETC_DIR/core-tested"\n[ ! -f "$XSS_ETC_DIR/reject-core" ]\n')
        core.chmod(0o755)

    def shell(self, code, *, success=True, env=None):
        result = subprocess.run(['bash', '-c', 'source "$1"\n' + MOCK_SERVICES + code,
                                 'logging-test', str(SCRIPT)], env=env or self.env,
                                text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def config(self):
        return json.loads(self.config_path.read_text())

    def write_config(self, data):
        self.config_path.write_text(json.dumps(data) + '\n')

    def marker(self, name):
        (self.root / 'etc' / name).touch()

    def restarts(self):
        events = self.root / 'etc/events'
        return events.read_text().splitlines().count('restart') if events.exists() else 0

    def backups(self):
        return list((self.root / 'etc/backups').glob('*.json'))

    def test_fresh_install_has_no_log_file_or_background_logger(self):
        self.assertEqual(self.config()['log'], dict(access='none', error='none', loglevel='none', dnsLog=False))
        self.assertFalse(self.log.exists())
        unit = (self.root / 'opt/standalone-service.sh').read_text()
        self.assertIn('>/dev/null 2>&1 </dev/null &', unit)
        self.assertNotIn('>>"$LOG"', unit)
        self.assertEqual(self.restarts(), 0)

    def test_switches_preserve_nodes_and_stopped_state(self):
        data = self.config()
        data['inbounds'] = [dict(tag='test-node', port=12345, protocol='shadowsocks')]
        data['routing'] = dict(domainStrategy='AsIs', rules=[])
        self.write_config(data)
        before = self.config()
        self.shell('set_logging on')
        enabled = self.config()
        self.assertEqual(enabled['log']['error'], str(self.log))
        self.assertEqual(enabled['log']['loglevel'], 'warning')
        self.assertEqual(enabled['log']['access'], 'none')
        self.assertFalse(enabled['log']['dnsLog'])
        self.assertEqual(self.log.stat().st_mode & 0o777, 0o600)
        self.shell('set_logging off')
        self.assertEqual(self.config(), before)
        self.assertEqual(self.restarts(), 0)
        self.assertFalse((self.root / 'etc/active').exists())

    def test_running_service_restarts_once_per_change(self):
        self.marker('active')
        self.shell('set_logging on')
        self.assertEqual(self.restarts(), 1)
        self.shell('set_logging off')
        self.assertEqual(self.restarts(), 2)
        self.assertTrue((self.root / 'etc/active').exists())

    def test_reapplying_settings_does_not_restart_or_add_backups(self):
        self.marker('active')
        self.shell('migrate_default_config\nset_logging off')
        self.assertEqual(self.restarts(), 0)
        self.assertEqual(self.backups(), [])
        self.shell('set_logging on')
        count = len(self.backups())
        self.shell('set_logging on\nmigrate_default_config')
        self.assertEqual(self.restarts(), 1)
        self.assertEqual(len(self.backups()), count)
        self.assertEqual(self.config()['log']['loglevel'], 'warning')

    def test_legacy_defaults_migrate_together_with_dns(self):
        data = dict(log=dict(loglevel='warning'), inbounds=[dict(tag='existing-node')],
                    outbounds=[dict(tag='direct', protocol='freedom')],
                    routing=dict(rules=[dict(type='field', outboundTag='direct')]))
        self.write_config(data)
        self.marker('active')
        self.shell('migrate_default_config')
        result = self.config()
        self.assertEqual(result['log']['loglevel'], 'none')
        self.assertEqual(result['inbounds'], data['inbounds'])
        self.assertEqual(result['routing'], data['routing'])
        self.assertTrue(result['dns']['servers'])
        self.assertEqual(result['outbounds'][0]['settings']['domainStrategy'], 'UseIPv4v6')
        self.assertEqual(self.restarts(), 1)
        self.assertEqual(len(self.backups()), 1)
        self.assertEqual(json.loads(self.backups()[0].read_text()), data)

    def test_custom_dns_and_logging_survive_upgrade(self):
        data = self.config()
        data['dns'] = dict(servers=['localhost'], queryStrategy='UseIPv6')
        data['outbounds'][0]['settings']['domainStrategy'] = 'UseIPv6'
        data['log'] = dict(loglevel='debug', access='/custom/access.log', error='/custom/error.log', dnsLog=True)
        self.write_config(data)
        self.shell('migrate_default_config')
        self.assertEqual(self.config(), data)
        self.assertEqual(self.backups(), [])

    def test_invalid_core_config_never_replaces_existing_files(self):
        self.marker('active')
        self.marker('reject-core')
        original = self.config_path.read_bytes()
        unit = (self.root / 'opt/standalone-service.sh').read_bytes()
        self.shell('set_logging on', success=False)
        self.assertEqual(self.config_path.read_bytes(), original)
        self.assertEqual((self.root / 'opt/standalone-service.sh').read_bytes(), unit)
        self.assertEqual(self.restarts(), 0)
        self.assertEqual(self.backups(), [])

    def test_invalid_json_is_rejected_without_core(self):
        Path(self.env['XSS_CORE_LINK']).unlink()
        original = self.config_path.read_bytes()
        self.shell('printf broken > "$ETC_DIR/candidate"\napply_runtime_config "$ETC_DIR/candidate" test', success=False)
        self.assertEqual(self.config_path.read_bytes(), original)

    def test_failed_restart_or_status_rolls_back_config_and_unit(self):
        for failure in ('fail-restart', 'fail-status'):
            with self.subTest(failure=failure):
                self.marker('active')
                self.marker(failure)
                unit = self.root / 'opt/standalone-service.sh'
                original_unit = unit.read_text().replace('>/dev/null', '>>"$LOG"')
                unit.write_text(original_unit)
                original = self.config_path.read_bytes()
                self.shell('set_logging on', success=False)
                self.assertEqual(self.config_path.read_bytes(), original)
                self.assertEqual(unit.read_text(), original_unit)
                self.assertTrue((self.root / 'etc/active').exists())
        self.assertEqual(self.restarts(), 4)

    def test_reload_failure_rolls_back_before_restart(self):
        self.marker('active')
        self.marker('fail-reload')
        original = self.config_path.read_bytes()
        self.shell('set_logging on', success=False)
        self.assertEqual(self.config_path.read_bytes(), original)
        self.assertEqual(self.restarts(), 1)

    def test_log_symlinks_cannot_be_opened_or_cleared(self):
        target = self.root / 'unrelated.txt'
        target.write_text('keep this data')
        self.log.parent.mkdir(exist_ok=True)
        self.log.symlink_to(target)
        original = self.config_path.read_bytes()
        self.shell('set_logging on', success=False)
        self.assertFalse((self.root / 'etc/core-tested').exists())
        self.shell('clear_logs', success=False)
        self.assertEqual(target.read_text(), 'keep this data')
        self.assertEqual(self.config_path.read_bytes(), original)

    def test_clear_logs_preserves_open_file_inode(self):
        self.shell('set_logging on')
        self.log.write_text('old warnings\n')
        inode = self.log.stat().st_ino
        self.shell('set_logging off')
        self.assertEqual(self.log.read_text(), 'old warnings\n')
        self.shell('clear_logs')
        self.assertEqual(self.log.read_bytes(), b'')
        self.assertEqual(self.log.stat().st_ino, inode)

    def test_unmanaged_or_symlink_service_is_not_overwritten(self):
        unit = self.root / 'opt/standalone-service.sh'
        unit.write_text('# unrelated service\n')
        original = self.config_path.read_bytes()
        self.shell('set_logging on', success=False)
        self.assertEqual(unit.read_text(), '# unrelated service\n')
        unit.unlink()
        target = self.root / 'unrelated-service'
        target.write_text('# XSS-MANAGED: xray-ss\n')
        unit.symlink_to(target)
        self.shell('set_logging on', success=False)
        self.assertEqual(target.read_text(), '# XSS-MANAGED: xray-ss\n')
        self.assertEqual(self.config_path.read_bytes(), original)

    def test_cli_and_menu_expose_log_controls(self):
        result = self.shell('main logs on\nmain logs off\nmain logs clear')
        self.assertIn('日志已开启', result.stdout)
        self.assertIn('日志已关闭', result.stdout)
        result = self.shell("service_menu <<<'5\n6\n7\n0'")
        self.assertIn('日志已开启', result.stdout)
        self.assertIn('日志已关闭', result.stdout)
        self.assertEqual(self.config()['log']['loglevel'], 'none')

    def test_all_service_templates_are_quiet_and_idempotent(self):
        paths = dict(systemd='units/xray-ss.service', openrc='init/openrc', sysvinit='init/sysv',
                     manual='opt/standalone-service.sh', runit='sv/xray-ss/run', procd='init/procd')
        for init, relative in paths.items():
            with self.subTest(init=init):
                env = dict(self.env, XSS_INIT_SYSTEM=init)
                self.shell('install_service_unit', env=env)
                unit = self.root / relative
                original = unit.read_bytes()
                self.shell('configure_service_log_output\nconfigure_service_log_output', env=env)
                self.assertEqual(unit.read_bytes(), original)
                text = unit.read_text()
                if init == 'systemd':
                    self.assertEqual(text.count('StandardOutput=null'), 1)
                    self.assertEqual(text.count('StandardError=null'), 1)
                    self.assertEqual(text.count('ReadWritePaths=-' + str(self.log)), 1)
                else:
                    subprocess.run(['sh', '-n', str(unit)], check=True)
                    if init == 'openrc':
                        self.assertIn('output_log="/dev/null"', text)
                        self.assertIn('error_log="/dev/null"', text)
                    elif init == 'procd':
                        self.assertIn('procd_set_param stdout 0', text)
                        self.assertIn('procd_set_param stderr 0', text)
                    else:
                        self.assertIn('>/dev/null 2>&1', text)
                        self.assertNotIn('>>', text)
        self.assertFalse(self.log.exists())

    def test_service_upgrade_preserves_custom_systemd_settings(self):
        self.env['XSS_INIT_SYSTEM'] = 'systemd'
        unit = Path(self.env['XSS_UNIT_FILE'])
        unit.parent.mkdir(exist_ok=True)
        unit.write_text('# XSS-MANAGED: xray-ss\n[Service]\n'
                        'Environment=KEEP_THIS=yes\nStandardOutput=journal\nStandardError=journal\n'
                        'ReadWritePaths=/custom/path\n[Install]\nWantedBy=multi-user.target\n')
        self.shell('configure_service_log_output')
        text = unit.read_text()
        self.assertIn('Environment=KEEP_THIS=yes', text)
        self.assertIn('ReadWritePaths=/custom/path', text)
        self.assertIn('StandardOutput=null', text)
        self.assertIn('StandardError=null', text)
        self.assertNotIn('StandardOutput=journal', text)
        self.assertIn('[Install]\nWantedBy=multi-user.target', text)


if __name__ == '__main__':
    unittest.main()
