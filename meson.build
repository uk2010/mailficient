project('mailficient', 'vala', 'c', version: '0.1.18', meson_version: '>= 1.3.0', default_options: ['warning_level=2'])

cc = meson.get_compiler('c')

gnome = import('gnome')
i18n = import('i18n')

gtk = dependency('gtk4', version: '>= 4.12')
adw = dependency('libadwaita-1', version: '>= 1.5')
gee = dependency('gee-0.8')
gio = dependency('gio-2.0')
json = dependency('json-glib-1.0')
sqlite = dependency('sqlite3')
secret = dependency('libsecret-1')
webkit = dependency('webkitgtk-6.0')
xml = dependency('libxml-2.0')
crypto = cc.find_library('crypto', required: true)
cairo = dependency('cairo')
pangocairo = dependency('pangocairo')

subdir('data')
subdir('src')

test_sources = files(
  'tests/test-core.vala',
  'src/models/message.vala',
  'src/models/mailbox.vala',
  'src/models/toolbar-layout.vala',
  'src/models/mail-sync-result.vala',
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
  'src/models/calendar-event.vala',
  'src/models/mail-task.vala',
  'src/models/mail-template.vala',
  'src/models/vacation-settings.vala',
  'src/mail/mail-repository.vala',
  'src/mail/demo-mail-repository.vala',
  'src/mail/cached-mail-repository.vala',
  'src/mail/virtual-message-model.vala',
  'src/services/search-query.vala',
  'src/services/conversation-builder.vala',
  'src/security/html-sanitizer.vala',
  'src/security/html-content-policy.vala',
  'src/security/attachment-safety.vala',
  'src/security/credential-store.vala',
  'src/security/credential-cleanup-service.vala',
  'src/security/remote-content-policy.vala',
  'src/services/attachment-service.vala',
  'src/services/received-attachment-service.vala',
  'src/services/draft-lifecycle-service.vala',
  'src/services/inline-content-resolver.vala',
  'src/services/outbound-service.vala',
  'src/services/mail-engine.vala',
  'src/services/sync-state.vala',
  'src/services/startup-sync-gate.vala',
  'src/services/account-sync-service.vala',
  'src/services/folder-service.vala',
  'src/services/message-sorter.vala',
  'src/services/signature-service.vala',
  'src/services/cache-maintenance-service.vala',
  'src/services/contact-suggestion-provider.vala',
  'src/services/recipient-completion-service.vala',
  'src/services/reply-recipient-service.vala',
  'src/services/online-account-service.vala',
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
core_tests = executable('core-tests', test_sources,
  include_directories: include_directories('src'),
  dependencies: [gee, gio, sqlite, xml, crypto, cairo, pangocairo],
  vala_args: ['--target-glib=2.76'])
test('core', core_tests, timeout: 300)

camel_test_dep = dependency('camel-1.2', required: false)
if camel_test_dep.found()
  camel_test_sources = files(
    'tests/test-camel.vala',
    'src/services/camel-mail-engine.vala',
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
    'src/models/remote-message-state.vala',
    'src/models/mailbox.vala',
    'src/models/message.vala',
    'src/models/mail-label.vala',
    'src/models/send-result.vala',
    'src/models/pending-mutation.vala',
    'src/services/online-account-service.vala',
  )
  camel_tests = executable('camel-tests', camel_test_sources,
    dependencies: [gee, gio, camel_test_dep],
    vala_args: ['--target-glib=2.76'] + camel_vala_args)
  test('camel', camel_tests)
endif

install_data('README.md', install_dir: get_option('datadir') / 'doc' / meson.project_name())
