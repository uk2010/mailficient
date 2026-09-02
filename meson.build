project('mailficient', 'vala', 'c', version: '0.7.0-beta.1', meson_version: '>= 1.3.0', default_options: ['warning_level=2'])

cc = meson.get_compiler('c')
gcal_archive = get_option('gcal-archive')
gcal_link_args = []
gcal_dependencies = []
if gcal_archive != ''
  gcal_libdir = get_option('gcal-libdir')
  gcal_dependencies = [
    cc.find_library('edataserverui4-1.0', dirs: gcal_libdir),
    cc.find_library('gweather-4', dirs: gcal_libdir),
    cc.find_library('geoclue-2', dirs: gcal_libdir),
    cc.find_library('fribidi', dirs: gcal_libdir),
    cc.find_library('edbus-private', dirs: gcal_libdir / 'evolution-data-server'),
    cc.find_library('m'),
  ]
  gcal_link_args = ['-Wl,--whole-archive', gcal_archive, '-Wl,--no-whole-archive']
endif

gnome = import('gnome')
i18n = import('i18n')

gtk = dependency('gtk4', version: '>= 4.12')
adw = dependency('libadwaita-1', version: '>= 1.5')
gee = dependency('gee-0.8')
gio = dependency('gio-2.0')
json = dependency('json-glib-1.0')
sqlite = dependency('sqlite3')
secret = dependency('libsecret-1')
webkit = dependency('webkitgtk-6.0', version: '>= ' + get_option('webkit-min-version'))
xml = dependency('libxml-2.0')
crypto = cc.find_library('crypto', required: true)
cairo = dependency('cairo')
pangocairo = dependency('pangocairo')

subdir('data')
subdir('src')

core_support_sources = files(
  'src/models/message.vala',
  'src/models/calendar-invitation.vala',
  'src/models/message-security-assessment.vala',
  'src/models/mailbox.vala',
  'src/models/toolbar-layout.vala',
  'src/models/mail-sync-result.vala',
  'src/models/remote-draft-location.vala',
  'src/models/remote-draft-snapshot.vala',
  'src/models/pending-draft-deletion.vala',
  'src/models/new-mail-summary.vala',
  'src/models/remote-message-state.vala',
  'src/models/pending-mutation.vala',
  'src/models/pending-transfer.vala',
  'src/models/pending-deletion.vala',
  'src/models/pending-folder-purge.vala',
  'src/models/send-result.vala',
  'src/models/outbox-item.vala',
  'src/models/cache-maintenance-result.vala',
  'src/models/reply-recipients.vala',
  'src/models/online-mail-account.vala',
  'src/models/oauth-access-token.vala',
  'src/models/junk-rule.vala',
  'src/models/mail-label.vala',
  'src/models/mail-rule.vala',
  'src/models/smart-mailbox.vala',
  'src/models/mail-task.vala',
  'src/models/mail-template.vala',
  'src/models/vacation-settings.vala',
  'src/mail/mail-repository.vala',
  'src/mail/demo-mail-repository.vala',
  'src/mail/cached-mail-repository.vala',
  'src/mail/virtual-message-model.vala',
  'src/services/search-query.vala',
  'src/services/server-search-expression.vala',
  'src/services/remote-mail-search-provider.vala',
  'src/services/mail-search-service.vala',
  'src/services/conversation-builder.vala',
  'src/services/notification-service.vala',
  'src/security/html-sanitizer.vala',
  'src/security/html-content-policy.vala',
  'src/security/attachment-safety.vala',
  'src/security/credential-store.vala',
  'src/security/credential-cleanup-service.vala',
  'src/security/remote-content-policy.vala',
  'src/security/message-security-service.vala',
  'src/services/attachment-service.vala',
  'src/services/icalendar-parser.vala',
  'src/services/calendar-integration-service.vala',
  'src/services/compose-safety-service.vala',
  'src/services/task-service.vala',
  'src/services/quick-step-service.vala',
  'src/services/received-attachment-service.vala',
  'src/services/draft-lifecycle-service.vala',
  'src/services/draft-fingerprint.vala',
  'src/services/draft-sync-service.vala',
  'src/services/inline-content-resolver.vala',
  'src/services/outbound-service.vala',
  'src/services/mail-engine.vala',
  'src/services/sync-state.vala',
  'src/services/startup-sync-gate.vala',
  'src/services/streamed-pass-refresh-gate.vala',
  'src/services/account-sync-service.vala',
  'src/services/live-mail-coordinator.vala',
  'src/services/folder-service.vala',
  'src/services/message-sorter.vala',
  'src/services/signature-service.vala',
  'src/services/cache-maintenance-service.vala',
  'src/services/contact-suggestion-provider.vala',
  'src/services/recipient-completion-service.vala',
  'src/services/reply-recipient-service.vala',
  'src/services/online-account-service.vala',
  'src/services/gnome-calendar-launcher.vala',
  'src/services/junk-filter-service.vala',
  'src/services/mail-rule-service.vala',
  'src/services/vacation-responder-service.vala',
  'src/services/message-export-service.vala',
  'src/services/account-provisioning-service.vala',
  'src/services/mobileconfig-importer.vala',
  'src/services/mobileconfig-decoder.c',
  'src/models/account-settings.vala',
  'src/models/draft.vala',
  'src/models/attachment.vala',
  'src/mail/mail-error.vala',
  'src/mail/recipient-parser.vala',
  'src/storage/cache-database.vala',
  'src/storage/account-store.vala',
  'src/storage/local-data-migration.vala',
  'src/storage/mail-settings-store.vala',
  'src/utils/debug-trace.vala',
)
core_tests = executable('core-tests', files('tests/test-core.vala') + core_support_sources,
  include_directories: include_directories('src'),
  dependencies: [gee, gio, sqlite, xml, crypto, cairo, pangocairo],
  vala_args: ['--target-glib=2.76'])
test('core', core_tests, timeout: 300)

rich_text_tests = executable('rich-text-tests',
  files('tests/test-rich-text.vala', 'src/ui/rich-text-buffer.vala'),
  include_directories: include_directories('src'),
  dependencies: [gtk, gee, json],
  vala_args: ['--target-glib=2.76'])
test('rich-text', rich_text_tests, timeout: 30)

draft_sync_tests = executable('draft-sync-tests',
  files('tests/test-draft-sync.vala') + core_support_sources,
  include_directories: include_directories('src'),
  dependencies: [gee, gio, sqlite, xml, crypto, cairo, pangocairo],
  vala_args: ['--target-glib=2.76'])
test('draft-sync', draft_sync_tests, timeout: 60)

calendar_tests = executable('calendar-tests',
  files('tests/test-calendar.vala') + core_support_sources,
  include_directories: include_directories('src'),
  dependencies: [gee, gio, sqlite, xml, crypto, cairo, pangocairo],
  vala_args: ['--target-glib=2.76'])
test('calendar', calendar_tests, timeout: 60)

background_autostart_tests = executable('background-autostart-tests',
  files('tests/test-background-autostart.vala',
        'src/services/background-autostart-service.vala'),
  dependencies: [gio],
  vala_args: ['--target-glib=2.76'])
test('background-autostart', background_autostart_tests, timeout: 30)

calendar_test_dep = dependency('libecal-2.0', required: false)
if calendar_test_dep.found()
  calendar_eds_tests = executable('calendar-eds-tests',
    files('tests/test-calendar-eds.vala',
          'src/services/eds-calendar-backend.vala') + core_support_sources,
    include_directories: include_directories('src'),
    dependencies: [gee, gio, sqlite, xml, crypto, cairo, pangocairo,
                   calendar_test_dep],
    vala_args: ['--target-glib=2.76'],
    c_args: ['-DLIBICAL_GLIB_UNSTABLE_API=1'])
  test('calendar-eds', calendar_eds_tests, timeout: 60)
endif

camel_test_dep = dependency('camel-1.2', required: false)
if camel_test_dep.found()
  edataserver_test_dep = dependency('libedataserver-1.2')
  camel_test_sources = files(
    'tests/test-camel.vala',
    'src/services/camel-cache-namespace.vala',
    'src/services/camel-mail-engine.vala',
    'src/services/remote-mail-search-provider.vala',
    'src/services/camel-live-mail-watch.vala',
    'src/services/received-attachment-store.vala',
    'src/services/attachment-service.vala',
    'src/services/mail-engine.vala',
    'src/services/sync-state.vala',
    'src/security/credential-store.vala',
    'src/security/attachment-safety.vala',
    'src/mail/mail-error.vala',
    'src/mail/recipient-parser.vala',
    'src/models/account-settings.vala',
    'src/models/online-mail-account.vala',
    'src/models/oauth-access-token.vala',
    'src/models/draft.vala',
    'src/models/attachment.vala',
    'src/models/mail-sync-result.vala',
    'src/models/remote-draft-location.vala',
    'src/models/remote-draft-snapshot.vala',
    'src/models/pending-draft-deletion.vala',
    'src/models/remote-message-state.vala',
    'src/models/mailbox.vala',
    'src/models/message.vala',
    'src/models/message-security-assessment.vala',
    'src/models/mail-label.vala',
    'src/models/send-result.vala',
    'src/models/pending-mutation.vala',
    'src/services/online-account-service.vala',
    'src/services/draft-fingerprint.vala',
    'src/security/html-sanitizer.vala',
    'src/security/html-content-policy.vala',
    'src/security/message-security-service.vala',
  )
  camel_tests = executable('camel-tests', camel_test_sources,
    dependencies: [gee, gio, xml, camel_test_dep, edataserver_test_dep],
    vala_args: ['--target-glib=2.76'] + camel_vala_args)
  test('camel', camel_tests)

  # This binary contains the test-only loopback certificate/authentication
  # seam used by tools/greenmail-qa.sh. Only its deterministic Draft UID cap
  # regression joins the normal suite; the network workflow is explicitly
  # gated and starts its own disposable GreenMail container.
  greenmail_test_sources = files(
    'tests/test-greenmail.vala',
    'src/services/camel-cache-namespace.vala',
    'src/services/camel-mail-engine.vala',
    'src/services/camel-live-mail-watch.vala',
    'src/services/received-attachment-store.vala',
  ) + core_support_sources
  greenmail_tests = executable('greenmail-tests', greenmail_test_sources,
    include_directories: include_directories('src'),
    dependencies: [gee, gio, sqlite, xml, crypto, cairo, pangocairo,
                   camel_test_dep, edataserver_test_dep],
    vala_args: ['--target-glib=2.76'] + camel_vala_args)
  test('camel-draft-cap', greenmail_tests,
    args: ['-p', '/camel/draft-uid-cap-converges'])
endif

install_data('README.md', 'RELEASE_NOTES.md',
  install_dir: get_option('datadir') / 'doc' / meson.project_name())
