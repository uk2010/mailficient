sources = files(
  'main.vala',
  'application/mail-application.vala',
  'models/account.vala',
  'models/mailbox.vala',
  'models/toolbar-layout.vala',
  'models/message.vala',
  'models/account-settings.vala',
  'models/draft.vala',
  'models/attachment.vala',
  'models/mail-sync-result.vala',
  'models/remote-message-state.vala',
  'models/pending-mutation.vala',
  'models/pending-transfer.vala',
  'models/pending-deletion.vala',
  'models/pending-folder-purge.vala',
  'models/send-result.vala',
  'models/outbox-item.vala',
  'models/cache-maintenance-result.vala',
  'models/reply-recipients.vala',
  'models/online-mail-account.vala',
  'models/oauth-access-token.vala',
  'models/junk-rule.vala',
  'models/mail-label.vala',
  'models/mail-rule.vala',
  'models/smart-mailbox.vala',
  'models/calendar-event.vala',
  'models/mail-task.vala',
  'models/mail-template.vala',
  'models/vacation-settings.vala',
  'mail/mail-error.vala',
  'mail/recipient-parser.vala',
  'mail/mail-repository.vala',
  'mail/demo-mail-repository.vala',
  'mail/demo-online-account-service.vala',
  'mail/cached-mail-repository.vala',
  'mail/virtual-message-model.vala',
  'services/search-query.vala',
  'services/conversation-builder.vala',
  'services/notification-service.vala',
  'services/mail-search-service.vala',
  'services/attachment-service.vala',
  'services/received-attachment-service.vala',
  'services/draft-lifecycle-service.vala',
  'services/inline-content-resolver.vala',
  'services/outbound-service.vala',
  'services/sync-state.vala',
  'services/startup-sync-gate.vala',
  'services/account-sync-service.vala',
  'services/folder-service.vala',
  'services/message-sorter.vala',
  'services/signature-service.vala',
  'services/cache-maintenance-service.vala',
  'services/contact-suggestion-provider.vala',
  'services/recipient-completion-service.vala',
  'services/reply-recipient-service.vala',
  'services/online-account-service.vala',
  'services/junk-filter-service.vala',
  'services/mail-rule-service.vala',
  'services/vacation-responder-service.vala',
  'services/message-export-service.vala',
  'services/account-provisioning-service.vala',
  'services/mobileconfig-importer.vala',
  'services/mobileconfig-decoder.c',
  'security/html-sanitizer.vala',
  'security/html-content-policy.vala',
  'security/attachment-safety.vala',
  'security/credential-store.vala',
  'security/credential-cleanup-service.vala',
  'security/remote-content-policy.vala',
  'security/libsecret-credential-store.vala',
  'utils/accessibility.vala',
  'utils/debug-trace.vala',
  'storage/cache-database.vala',
  'storage/account-store.vala',
  'storage/local-data-migration.vala',
  'storage/mail-settings-store.vala',
  'services/mail-engine.vala',
  'ui/mail-window.vala',
  'ui/toolbar-customization-dialog.vala',
  'ui/startup-error-window.vala',
  'ui/pane-resize-handle.vala',
  'ui/mailbox-sidebar.vala',
  'ui/message-list.vala',
  'ui/message-row.vala',
  'ui/reading-pane.vala',
  'ui/attachment-preview-window.vala',
  'ui/compose-window.vala',
  'ui/outbox-status-view.vala',
  'ui/compose-header.vala',
  'ui/rich-text-buffer.vala',
  'ui/account-dialog.vala',
  'ui/provider-chooser-dialog.vala',
  'ui/account-manager-dialog.vala',
  'ui/account-settings-page.vala',
  'ui/online-account-dialog.vala',
  'ui/preferences-window.vala',
  'ui/shortcuts-dialog.vala',
  'ui/recipient-completion-controller.vala',
  'ui/contact-picker-window.vala',
  'ui/calendar-tasks-window.vala',
  'ui/html-message-view.vala',
)

deps = [gtk, adw, gee, gio, json, sqlite, secret, webkit, xml, crypto, cairo, pangocairo]
camel = dependency('camel-1.2', required: get_option('camel'))
if camel.found()
  sources += files(
    'services/camel-mail-engine.vala',
    'services/received-attachment-store.vala',
  )
  deps += camel
  camel_vala_args = ['--define=HAVE_CAMEL']
  if camel.version().version_compare('<3.58')
    camel_vala_args += ['--define=EDS_LEGACY']
  endif
else
  camel_vala_args = []
endif

addressbook = dependency('libebook-1.2', required: get_option('addressbook'))
if addressbook.found()
  sources += files('services/gnome-address-book-provider.vala')
  deps += addressbook
  addressbook_vala_args = ['--define=HAVE_ADDRESS_BOOK']
  executable('mailficient-addressbook-probe',
    files(
      'addressbook-probe.vala',
      'services/contact-suggestion-provider.vala',
      'services/gnome-address-book-provider.vala',
      'mail/recipient-parser.vala',
      'mail/mail-error.vala',
    ),
    dependencies: [gee, gio, addressbook],
    vala_args: ['--target-glib=2.76'],
    install: true,
  )
else
  addressbook_vala_args = []
endif

executable('mailficient', sources, mailficient_resources,
  dependencies: deps,
  vala_args: ['--target-glib=2.76'] + camel_vala_args + addressbook_vala_args,
  install: true,
)
