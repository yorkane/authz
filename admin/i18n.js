(function () {
  const messages = {
    'zh-CN': {
      menu: {
        workspace: '工作区', users: '用户与角色', usersTitle: '用户 / 角色管理',
        authorization: '授权策略', authorizationTitle: '授权管理', logout: '注销', language: 'English',
        collapse: '收起菜单', expand: '展开菜单',
        localApps: '本地服务', localAppsHint: '自动发现的本机 HTTP 端口（未绑定域名）',
        domainApps: '域名服务', domainAppsHint: '已绑定域名的应用',
        emptyGroup: '（空）',
        files: '文件浏览', filesTitle: '浏览并预览挂载的文件目录',
        nginxConf: 'Nginx配置(危险)', nginxConfTitle: '编辑 nginx 自定义 include 并热重载',
        systemApps: '系统应用', systemAppsHint: '网关内置的管理与展示页面',
        menuEditor: '菜单编辑', menuEditorTitle: '左侧菜单排序、显示与入口管理'
      },
      files: {
        title: '文件浏览', description: '浏览挂载目录，支持图片 / 音频 / 视频 / HTML 预览与下载。',
        search: '搜索文件名', sortBy: '排序', sortName: '名称', sortSize: '大小', sortTime: '修改时间',
        sortOrder: '切换升 / 降序', refresh: '刷新', root: '根目录', folder: '目录', name: '名称', size: '大小', modified: '修改时间',
        foldersUnit: '个目录', filesUnit: '个文件',
        pageOf: '第 %s / %n 页', perPage: '每页',
        empty: '目录为空', emptyFilter: '没有匹配的文件', noPreview: '不支持在线预览，可下载查看',
        openInTab: '新窗口打开', download: '下载', close: '关闭', retry: '重试',
        textTooLarge: '文件过大，不适合在线预览',
        truncated: '目录条目过多，仅显示前 2000 条',
        kbdHint: '快捷键：↑ ↓ ← → 移动 · Enter 打开 · Backspace 返回上级 · g/l/d 切换视图 · f 搜索 · Esc 关闭预览'
      },
      nginxConf: {
        title: 'Nginx 配置（危险）',
        description: '编辑网关的三个用户自定义 include 文件；保存前必须先通过 nginx -t 校验，保存后需点击重载才会生效。',
        danger: '错误配置在重载后可能导致网关无法正常工作，请确认你了解 nginx 配置语法。',
        confDir: '配置目录', templateDir: '模板目录',
        persistent: '编辑会写回模板目录，容器重启后仍然保留',
        ephemeral: '模板目录只读：编辑仅存在于运行容器，重建容器后将丢失',
        loadError: '无法读取配置文件', retry: '重试', reloadFiles: '重新读取',
        modified: '未保存的修改', saved: '已保存', truncated: '文件过大，内容已截断显示',
        validate: '校验 (nginx -t)', validating: '校验中…', validationPassed: 'nginx -t 通过', validationFailed: 'nginx -t 失败',
        save: '保存', saving: '保存中…', saveConfirmTitle: '保存配置',
        saveConfirm: '将以编辑内容覆盖写入 %s（保留一份 .bak 备份）。写入前会再次执行 nginx -t 校验。',
        saveAction: '确认保存', saveDone: '已保存', savedNotApplied: '已保存，尚未重载生效',
        savedMirrored: '已保存并同步到模板目录', savedNotPersistent: '已保存到运行容器（容器重建后将丢失）',
        cancel: '取消',
        reload: 'nginx 重启', reloading: '重载中…', reloadConfirmTitle: '重载 nginx',
        reloadConfirm: '将执行 nginx -s reload（优雅重载，不中断现有连接）。确定继续？',
        reloadAction: '确认重载', reloadDone: 'nginx 已重载', reloadFailed: 'nginx 重载失败',
        saveFirstTitle: '有未保存的修改', saveFirst: '当前标签页还有未保存的修改，请先保存后再重载。',
        ok: '操作成功', failed: '操作失败',
        httpHint: 'http{} 层：map、upstream、server 站点、缓存等。',
        serverHint: 'server{} 层：只允许 location 级指令，会追加到网关 server 块末尾。',
        streamHint: 'stream{} 层：TCP/UDP 四层代理 server 块。',
        emptyFile: '（空文件）', charLimit: '单个文件上限 256 KiB'
      },
      users: {
        title: '用户与角色', description: '集中管理登录账户、角色和凭据安全。', create: '新建用户',
        accounts: '账户总数', accountsNote: '网关身份', enabled: '启用', disabled: '未启用', enabledNote: '允许登录',
        roles: '角色数量', rolesNote: '不同访问角色', allUsers: '全部用户', protectedAdmin: '管理员账户受到额外保护', myProfile: '我的信息', myProfileNote: '仅显示当前登录身份与角色',
        search: '搜索用户、来源或角色', user: '用户', source: '来源', local: '本地', dingtalk: '钉钉', wechat: '微信', role: '角色', status: '状态', createdAt: '创建日期', lastLoginAt: '用户登录日期', updatedAt: '修改日期',
        builtIn: '内置账户', noData: '没有匹配的用户', myPassword: '我的密码', passwordNote: '更新后所有登录会话将失效，请重新登录',
        changePassword: '修改密码', retry: '重试', cancel: '取消', save: '保存', reset: '重置',
        createTitle: '新建用户', createCopy: '创建可登录网关的身份账户。', username: '用户名', initialPassword: '初始密码',
        roleHint: '从 admin、staff、user、viewer 中选择一个或多个角色', createAction: '创建用户', rolesTitle: '设置角色', rolesHint: '角色用于统一控制管理和应用访问权限',
        resetTitle: '重置密码', resetCopy: '设置新密码', newPassword: '新密码', confirmNewPassword: '确认新密码', passwordMismatch: '两次输入的新密码不一致', myPasswordTitle: '修改我的密码',
        myPasswordCopy: '请先验证当前密码。', currentPassword: '当前密码', updatePassword: '更新密码',
        required: '此项不能为空', usernameRule: '使用 2-32 位小写字母、数字、_ 或 -', passwordRule: '密码至少 6 位', roleRule: '请从 admin、staff、user、viewer 中至少选择一个角色',
        created: '用户已创建', rolesUpdated: '角色已更新', passwordReset: '密码已重置', enabledDone: '用户已设为启用',
        disabledDone: '用户已设为未启用', disableTitle: '设为未启用', disableConfirm: '该用户的现有会话将失效，并且无法继续登录。',
        deleteTitle: '删除用户', deleteConfirm: '此操作无法撤销。', deleteRemoteConfirm: '将删除本机身份记录、会话和直接授权；下次认证时会重新记录。', deleteAction: '删除', deleted: '用户已删除', passwordUpdated: '密码已更新',
        remoteRoles: '远端角色记录', remoteRolesHint: '保存只覆盖本机有效角色，不会回写身份源；下次登录仅刷新远端记录', remoteRolesUpdated: '本机角色覆盖已保存', restoreRemote: '恢复记录角色', restoreRemoteConfirm: '将清除本机角色覆盖并恢复最近记录的远端角色。', remoteRolesRestored: '已恢复记录角色'
      },
      authorization: {
        title: '授权管理', description: '管理入口映射与 Casbin 访问决策。', addBinding: '新增绑定', addPolicy: '新增策略',
        bindings: '域名绑定', bindingsNote: '固定路由', allowPolicies: '允许策略', allowNote: '允许访问', denyPolicies: '拒绝策略', denyNote: '拒绝优先',
        routesTitle: '域名与端口绑定', routesCopy: '固定域名映射到本机或其他 IP 的 HTTP 服务', routeCount: '条路由', domain: '域名前缀', targetIp: '目标 IP', port: '端口', status: '状态', note: '备注', menuName: '菜单名称', websocket: 'WebSocket', proxyMode: '代理方式', noBindings: '尚未创建固定绑定',
        policiesTitle: 'Casbin 策略', policiesCopy: '拒绝规则优先匹配；对象格式为 /<端口><路径>', search: '搜索主体或对象',
        type: '类型', subject: '主体', objectRole: '对象 / 角色', action: '动作', effect: '效果', retry: '重试', cancel: '取消', local: '本地', dingtalk: '钉钉', wechat: '微信',
        bindingTitle: '新增域名绑定', editBindingTitle: '编辑域名绑定', bindingCopy: '填写最后一级前缀与目标地址；代理细节按需展开。', domainPlaceholder: 'name1', targetIpPlaceholder: '127.0.0.1', targetIpHint: '默认代理本机；也可填写其他机器的 IPv4 或 IPv6 地址', menuNameHint: '填写后直接作为左侧菜单名称', websocketEnabled: 'WebSocket 自动代理', websocketHint: '所有目标默认支持升级请求', enabledNow: '立即启用', createBinding: '创建绑定', saveBinding: '保存绑定', editBinding: '编辑绑定',
        advancedProxy: '高级代理配置', advancedProxyHint: '上游协议、路径改写、Host、Forwarded 与 Origin', upstreamScheme: '上游协议', sslVerify: '验证 SSL 证书', sslVerifyHint: '仅 HTTPS 生效；关闭后忽略上游证书错误', upstreamPath: '上游路径改写', upstreamPathPlaceholder: '例如 /api/index.html', upstreamPathHint: '填写后将请求统一转发到此路径；留空保持原路径', sslVerification: 'SSL 校验', sslVerified: '已开启', sslIgnored: '已忽略', notApplicable: '不适用', upstreamHost: '上游 Host', upstreamHostPlaceholder: '留空：使用访问域名', upstreamHostHint: '发送给后端的 Host 请求头', forwardedHost: 'X-Forwarded-Host', forwardedHostPlaceholder: '留空：跟随上游 Host', forwardedHostHint: '发送给后端的原始主机名', forwardedProto: 'X-Forwarded-Proto', forwardedPort: 'X-Forwarded-Port', autoValue: '自动', originMode: 'Origin 处理', originAuto: '自动（默认保持）', originPreserve: '保持请求值', originRewrite: '按代理地址重写', originRemove: '移除 Origin', originCustom: '使用自定义值', customOrigin: '自定义 Origin', simulateLocal: '模拟本机访问', simulateLocalHint: '使用目标地址作为默认 Host，并把来源请求头改为指定的本机或局域网 IP', localIp: '模拟来源 IP', localIpHint: '默认 127.0.0.1；也可填写网关局域网 IP', proxyDefault: '默认', proxyCustom: '自定义', proxyLocal: '模拟本机', headerOverrides: 'Header 覆盖', headerOverridesPlaceholder: 'X-Custom-Header: value', headerOverridesHint: '每行一条，格式 Header-Name: value，按行覆盖发往上游的请求头；Host、Cookie、X-Authz-* 等网关头不可覆盖',
        policyTitle: '新增访问策略', editPolicyTitle: '编辑访问策略', policyCopy: '创建 P 类型访问授权规则。', user: '用户', role: '角色', object: '对象', objectAddress: '绑定对象', objectPath: '访问路径', objectPreview: '授权对象', httpAction: 'HTTP 动作', createPolicy: '创建策略', savePolicy: '保存策略', editPolicy: '编辑策略',
        subjectHint: '选择角色或具体用户', userHint: '选择需要分配角色的用户', roleHint: '策略主体支持 admin、staff、user、viewer 或 api', objectHint: '按菜单名、域名和目标地址选择；也可输入 /<端口><路径>', objectAddressRule: '请选择绑定对象或输入 /<端口><路径>', objectPathRule: '路径必须以 / 开头，且不能包含空格或逗号', httpActionHint: '可选择多个标准 HTTP 方法；* 表示全部方法', allObjects: '全部地址 · /*', allObjectsHint: '匹配所有绑定、端口和路径', directPort: '直接端口', sharedBindings: '个绑定共享', unboundObject: '未找到对应绑定', invalidObject: '无效对象', allActions: '全部方法 · *', allow: '允许', deny: '拒绝', assigned: '已分配',
        deleteBinding: '删除绑定', deletePolicy: '删除策略',
        required: '此项不能为空', bindingCreated: '绑定已创建', bindingUpdated: '绑定已更新', bindingDisabled: '绑定已停用', bindingEnabled: '绑定已启用',
        deleteBindingTitle: '删除域名绑定', deleteBindingConfirm: '确认删除此域名绑定？', deleteAction: '删除', bindingDeleted: '绑定已删除',
        policyCreated: '策略已创建', policyUpdated: '策略已更新', deletePolicyTitle: '删除访问策略', deletePolicyConfirm: '权限结果可能立即改变。', policyDeleted: '策略已删除'
      },
      menuEditor: {
        title: '菜单编辑', description: '管理左侧菜单的自定义入口、显示与排序。',
        addEntry: '新增入口', addGroup: '新增分组', entries: '菜单树', entriesNote: '分组与条目构成左侧菜单布局',
        label: '名称', labelServiceHint: '留空则恢复默认名称', url: '入口地址', icon: '图标', sortOrder: '排序', enabled: '启用', actions: '操作',
        groupKind: '分组', itemKind: '条目', parentGroup: '所属分组', builtinHint: '内置页面',
        dynamicGroupHint: '“本地服务”分组自动汇集端口探测发现的本机服务（未绑定域名）；可改名、换图标、排序、隐藏，不可删除。',
        domainsGroupHint: '“域名服务”分组自动汇集已绑定域名的应用（含其直连端口入口）；改名会同步到域名绑定的菜单名，可隐藏但不可删除。',
        labelPlaceholder: '例如 监控面板', urlPlaceholder: '例如 /_authz/apps/users.html 或 https://example.com',
        iconPlaceholder: 'MDI 图标名，例如 mdi-monitor', iconHint: '留空使用默认图标',
        createTitle: '新增菜单入口', createCopy: '选择所属分组并填写名称与入口地址。',
        createGroupTitle: '新增分组', createGroupCopy: '分组会作为左侧菜单的一级折叠标题。',
        editTitle: '编辑菜单入口', editGroupTitle: '编辑分组', create: '创建', save: '保存', cancel: '取消',
        editServiceTitle: '编辑服务菜单项', editServiceCopy: '服务条目由绑定/端口探测自动生成：这里只改菜单显示名与图标，域名条目改名会同步到绑定的菜单名称。',
        restoreDefault: '恢复默认', restoredDefault: '已恢复默认菜单项',
        serviceHint: '服务', hiddenHint: '已隐藏',
        moveUp: '上移', moveDown: '下移', reorder: '保存排序', collapse: '收起分组', expand: '展开分组',
        enableToggle: '显示', disableToggle: '隐藏',
        noEntries: '尚未配置菜单，点击“新增分组”开始。',
        required: '此项不能为空', urlRule: '必须以 / 或 http://、https:// 开头',
        created: '菜单已创建', updated: '菜单已更新', deleted: '菜单已删除',
        reordered: '菜单顺序已保存',
        deleteTitle: '删除菜单入口', deleteConfirm: '此操作无法撤销。', deleteAction: '删除',
        deleteGroupTitle: '删除分组', deleteGroupConfirm: '分组下不能有条目才能删除；此操作无法撤销。',
        cannotDeleteGroup: '该分组下仍有条目，请先移动或删除条目。',
        enableDone: '入口已设为显示', disableDone: '入口已设为隐藏',
        retry: '重试'
      }
    },
    'en-US': {
      menu: {
        workspace: 'Workspace', users: 'Users & Roles', usersTitle: 'Users & Roles',
        authorization: 'Authorization', authorizationTitle: 'Authorization', logout: 'Logout', language: '中文',
        collapse: 'Collapse menu', expand: 'Expand menu',
        localApps: 'Local services', localAppsHint: 'Discovered local HTTP ports (no domain binding)',
        domainApps: 'Domain services', domainAppsHint: 'Applications with domain bindings',
        emptyGroup: '(empty)',
        files: 'File Browser', filesTitle: 'Browse and preview the mounted file directory',
        nginxConf: 'Nginx Config (danger)', nginxConfTitle: 'Edit nginx include files and hot-reload',
        systemApps: 'System apps', systemAppsHint: 'Built-in management and demo pages',
        menuEditor: 'Menu editor', menuEditorTitle: 'Left-menu ordering, visibility and entries'
      },
      files: {
        title: 'File Browser', description: 'Browse the mounted directory with image / audio / video / HTML preview and download.',
        search: 'Search file name', sortBy: 'Sort', sortName: 'Name', sortSize: 'Size', sortTime: 'Modified',
        sortOrder: 'Toggle sort order', refresh: 'Refresh', root: 'Root', folder: 'Folder', name: 'Name', size: 'Size', modified: 'Modified',
        foldersUnit: 'folders', filesUnit: 'files',
        pageOf: 'page %s of %n', perPage: 'Per page',
        empty: 'Empty directory', emptyFilter: 'No matching files', noPreview: 'No inline preview; download to view',
        openInTab: 'Open in tab', download: 'Download', close: 'Close', retry: 'Retry',
        textTooLarge: 'File too large for inline preview',
        truncated: 'Too many entries; only the first 2000 are listed',
        kbdHint: 'Shortcuts: arrows move · Enter opens · Backspace goes up · g/l/d switch view · f search · Esc closes preview'
      },
      nginxConf: {
        title: 'Nginx Configuration (danger)',
        description: 'Edit the three operator-authored nginx include files; a passing nginx -t check is required before saving, and a reload applies the change.',
        danger: 'A broken configuration reloaded into the live gateway can disrupt it. Make sure you understand nginx configuration syntax.',
        confDir: 'Conf directory', templateDir: 'Template directory',
        persistent: 'Edits are mirrored to the template directory and survive container restarts',
        ephemeral: 'Template directory is read-only: edits live in the running container only and are lost on recreate',
        loadError: 'Cannot read configuration files', retry: 'Retry', reloadFiles: 'Reload files',
        modified: 'Unsaved changes', saved: 'Saved', truncated: 'File too large; content truncated',
        validate: 'Validate (nginx -t)', validating: 'Validating…', validationPassed: 'nginx -t passed', validationFailed: 'nginx -t failed',
        save: 'Save', saving: 'Saving…', saveConfirmTitle: 'Save configuration',
        saveConfirm: 'Overwrite %s with the edited content (one .bak backup kept). nginx -t runs again before writing.',
        saveAction: 'Save', saveDone: 'Saved', savedNotApplied: 'Saved; reload required to apply',
        savedMirrored: 'Saved and mirrored to the template directory', savedNotPersistent: 'Saved in the running container (lost on container recreate)',
        cancel: 'Cancel',
        reload: 'nginx reload', reloading: 'Reloading…', reloadConfirmTitle: 'Reload nginx',
        reloadConfirm: 'Run nginx -s reload (graceful, keeps existing connections). Continue?',
        reloadAction: 'Reload', reloadDone: 'nginx reloaded', reloadFailed: 'nginx reload failed',
        saveFirstTitle: 'Unsaved changes', saveFirst: 'The active tab has unsaved changes; save them before reloading.',
        ok: 'Done', failed: 'Operation failed',
        httpHint: 'http{} scope: map, upstream, servers, caches, etc.',
        serverHint: 'server{} scope: location-level directives only; appended after the gateway server block.',
        streamHint: 'stream{} scope: TCP/UDP layer-4 proxy server blocks.',
        emptyFile: '(empty file)', charLimit: 'Up to 256 KiB per file'
      },
      users: {
        title: 'Users & Roles', description: 'Manage sign-in accounts, roles, and credential security.', create: 'New user',
        accounts: 'Total accounts', accountsNote: 'Gateway identities', enabled: 'Enabled', disabled: 'Disabled', enabledNote: 'Allowed to sign in',
        roles: 'Roles', rolesNote: 'Distinct access roles', allUsers: 'All users', protectedAdmin: 'The administrator account has additional protection', myProfile: 'My profile', myProfileNote: 'Only the current identity and roles are shown',
        search: 'Search users, sources, or roles', user: 'User', source: 'Source', local: 'Local', dingtalk: 'DingTalk', wechat: 'WeChat', role: 'Role', status: 'Status', createdAt: 'Created at', lastLoginAt: 'Last login at', updatedAt: 'Updated at',
        builtIn: 'Built-in', noData: 'No matching users', myPassword: 'My password', passwordNote: 'All sessions expire after an update; sign in again',
        changePassword: 'Change password', retry: 'Retry', cancel: 'Cancel', save: 'Save', reset: 'Reset',
        createTitle: 'New user', createCopy: 'Create an identity that can sign in to the gateway.', username: 'Username', initialPassword: 'Initial password',
        roleHint: 'Select one or more roles from admin, staff, user, and viewer', createAction: 'Create user', rolesTitle: 'Set roles', rolesHint: 'Roles consistently control administrative and application access',
        resetTitle: 'Reset password', resetCopy: 'Set a new password', newPassword: 'New password', confirmNewPassword: 'Confirm new password', passwordMismatch: 'The new passwords do not match', myPasswordTitle: 'Change my password',
        myPasswordCopy: 'Verify the current password first.', currentPassword: 'Current password', updatePassword: 'Update password',
        required: 'This field is required', usernameRule: 'Use 2-32 lowercase letters, numbers, _ or -', passwordRule: 'Password must be at least 6 characters', roleRule: 'Select at least one of admin, staff, user, or viewer',
        created: 'User created', rolesUpdated: 'Roles updated', passwordReset: 'Password reset', enabledDone: 'User enabled',
        disabledDone: 'User disabled', disableTitle: 'Disable user', disableConfirm: 'Existing sessions expire and this user can no longer sign in.',
        deleteTitle: 'Delete user', deleteConfirm: 'This action cannot be undone.', deleteRemoteConfirm: 'The local identity record, sessions, and direct grants are removed. The identity is recorded again on its next authentication.', deleteAction: 'Delete', deleted: 'User deleted', passwordUpdated: 'Password updated',
        remoteRoles: 'Recorded remote roles', remoteRolesHint: 'Saving only overrides effective local roles and never writes back to the identity provider; the next login only refreshes the record', remoteRolesUpdated: 'Local role override saved', restoreRemote: 'Restore recorded roles', restoreRemoteConfirm: 'Clear the local override and restore the most recently recorded remote roles.', remoteRolesRestored: 'Recorded roles restored'
      },
      authorization: {
        title: 'Authorization', description: 'Manage gateway mappings and Casbin access decisions.', addBinding: 'Add binding', addPolicy: 'Add policy',
        bindings: 'Domain bindings', bindingsNote: 'Explicit routes', allowPolicies: 'Allow policies', allowNote: 'Allow decisions', denyPolicies: 'Deny policies', denyNote: 'Deny takes priority',
        routesTitle: 'Domain and port bindings', routesCopy: 'Map fixed domains to HTTP services on this or another IP', routeCount: 'routes', domain: 'Domain prefix', targetIp: 'Target IP', port: 'Port', status: 'Status', note: 'Note', menuName: 'Menu name', websocket: 'WebSocket', proxyMode: 'Proxy mode', noBindings: 'No fixed bindings yet',
        policiesTitle: 'Casbin policies', policiesCopy: 'Deny rules match first; object format is /<port><path>', search: 'Search subjects or objects',
        type: 'Type', subject: 'Subject', objectRole: 'Object / Role', action: 'Action', effect: 'Effect', retry: 'Retry', cancel: 'Cancel', local: 'Local', dingtalk: 'DingTalk', wechat: 'WeChat',
        bindingTitle: 'Add domain binding', editBindingTitle: 'Edit domain binding', bindingCopy: 'Enter the last-level prefix and target; expand proxy details only when needed.', domainPlaceholder: 'name1', targetIpPlaceholder: '127.0.0.1', targetIpHint: 'Defaults to this host; another IPv4 or IPv6 address is also accepted', menuNameHint: 'When set, this is used in the left menu', websocketEnabled: 'WebSocket auto-proxy', websocketHint: 'Upgrade requests are supported for every target', enabledNow: 'Enable now', createBinding: 'Create binding', saveBinding: 'Save binding', editBinding: 'Edit binding',
        advancedProxy: 'Advanced proxy settings', advancedProxyHint: 'Upstream protocol, path rewrite, Host, Forwarded, and Origin', upstreamScheme: 'Upstream protocol', sslVerify: 'Verify SSL certificate', sslVerifyHint: 'HTTPS only; turn off to ignore upstream certificate errors', upstreamPath: 'Upstream path rewrite', upstreamPathPlaceholder: 'For example /api/index.html', upstreamPathHint: 'Forward every request to this path; blank keeps the original path', sslVerification: 'SSL verification', sslVerified: 'Enabled', sslIgnored: 'Ignored', notApplicable: 'N/A', upstreamHost: 'Upstream Host', upstreamHostPlaceholder: 'Blank: use request domain', upstreamHostHint: 'Host header sent to the upstream', forwardedHost: 'X-Forwarded-Host', forwardedHostPlaceholder: 'Blank: follow upstream Host', forwardedHostHint: 'Original host reported to the upstream', forwardedProto: 'X-Forwarded-Proto', forwardedPort: 'X-Forwarded-Port', autoValue: 'Auto', originMode: 'Origin handling', originAuto: 'Auto (preserve by default)', originPreserve: 'Preserve request value', originRewrite: 'Rewrite to proxy address', originRemove: 'Remove Origin', originCustom: 'Use custom value', customOrigin: 'Custom Origin', simulateLocal: 'Simulate local access', simulateLocalHint: 'Use the target as the default Host and replace source headers with a local or LAN address', localIp: 'Simulated source IP', localIpHint: 'Defaults to 127.0.0.1; the gateway LAN IP is also accepted', proxyDefault: 'Default', proxyCustom: 'Custom', proxyLocal: 'Local simulation', headerOverrides: 'Header overrides', headerOverridesPlaceholder: 'X-Custom-Header: value', headerOverridesHint: 'One per line as Header-Name: value; overrides request headers sent upstream. Gateway-managed headers such as Host, Cookie, and X-Authz-* cannot be overridden',
        policyTitle: 'Add access policy', editPolicyTitle: 'Edit access policy', policyCopy: 'Create a P-type access authorization rule.', user: 'User', role: 'Role', object: 'Object', objectAddress: 'Binding target', objectPath: 'Access path', objectPreview: 'Policy object', httpAction: 'HTTP action', createPolicy: 'Create policy', savePolicy: 'Save policy', editPolicy: 'Edit policy',
        subjectHint: 'Select a role or a specific user', userHint: 'Select the user receiving the role', roleHint: 'Policy subjects support admin, staff, user, viewer, or api', objectHint: 'Select by menu, domain, and target; or enter /<port><path>', objectAddressRule: 'Select a binding or enter /<port><path>', objectPathRule: 'Path must start with / and contain no spaces or commas', httpActionHint: 'Select multiple standard HTTP methods; * matches every method', allObjects: 'All objects · /*', allObjectsHint: 'Matches every binding, port, and path', directPort: 'Direct port', sharedBindings: 'shared bindings', unboundObject: 'No matching binding', invalidObject: 'Invalid object', allActions: 'All methods · *', allow: 'Allow', deny: 'Deny', assigned: 'Assigned',
        deleteBinding: 'Delete binding', deletePolicy: 'Delete policy',
        required: 'This field is required', bindingCreated: 'Binding created', bindingUpdated: 'Binding updated', bindingDisabled: 'Binding disabled', bindingEnabled: 'Binding enabled',
        deleteBindingTitle: 'Delete domain binding', deleteBindingConfirm: 'Delete this domain binding?', deleteAction: 'Delete', bindingDeleted: 'Binding deleted',
        policyCreated: 'Policy created', policyUpdated: 'Policy updated', deletePolicyTitle: 'Delete access policy', deletePolicyConfirm: 'Authorization results may change immediately.', policyDeleted: 'Policy deleted'
      },
      menuEditor: {
        title: 'Menu editor', description: 'Manage custom entries, visibility, and order of the left menu.',
        addEntry: 'Add entry', addGroup: 'Add group', entries: 'Menu tree', entriesNote: 'Groups and items form the left-menu layout',
        label: 'Label', labelServiceHint: 'Leave blank to restore the default name', url: 'Entry URL', icon: 'Icon', sortOrder: 'Order', enabled: 'Visible', actions: 'Actions',
        groupKind: 'Group', itemKind: 'Item', parentGroup: 'Parent group', builtinHint: 'Built-in page',
        dynamicGroupHint: 'The "Local services" group auto-collects discovered local services (no domain binding); rename, icon, order and hiding are editable, deletion is not.',
        domainsGroupHint: 'The "Domain services" group auto-collects applications with domain bindings (plus their direct port entries); renaming syncs the binding menu name, entries can be hidden but not deleted.',
        labelPlaceholder: 'e.g. Monitoring', urlPlaceholder: 'e.g. /_authz/apps/users.html or https://example.com',
        iconPlaceholder: 'MDI icon name, e.g. mdi-monitor', iconHint: 'Leave blank for the default icon',
        createTitle: 'Add menu entry', createCopy: 'Pick a parent group, then set a name and URL.',
        createGroupTitle: 'Add group', createGroupCopy: 'The group becomes a top-level collapse in the left menu.',
        editTitle: 'Edit menu entry', editGroupTitle: 'Edit group', create: 'Create', save: 'Save', cancel: 'Cancel',
        editServiceTitle: 'Edit service menu item', editServiceCopy: 'Service entries come from bindings/port discovery: only the menu label and icon change here. Renaming a domain entry updates the binding menu name.',
        restoreDefault: 'Restore default', restoredDefault: 'Menu entry restored to default',
        serviceHint: 'Service', hiddenHint: 'Hidden',
        moveUp: 'Move up', moveDown: 'Move down', reorder: 'Save order', collapse: 'Collapse group', expand: 'Expand group',
        enableToggle: 'Show', disableToggle: 'Hide',
        noEntries: 'No menu configured. Click "Add group" to start.',
        required: 'This field is required', urlRule: 'Must start with / or http://, https://',
        created: 'Menu entry created', updated: 'Menu entry updated', deleted: 'Menu entry deleted',
        reordered: 'Menu order saved',
        deleteTitle: 'Delete menu entry', deleteConfirm: 'This action cannot be undone.', deleteAction: 'Delete',
        deleteGroupTitle: 'Delete group', deleteGroupConfirm: 'A group can only be deleted when empty; this cannot be undone.',
        cannotDeleteGroup: 'This group still has items; move or delete them first.',
        enableDone: 'Entry is now visible', disableDone: 'Entry is now hidden',
        retry: 'Retry'
      }
    }
  }

  function normalize (locale) {
    return locale === 'en-US' ? 'en-US' : 'zh-CN'
  }

  function getLocale () {
    return normalize(window.localStorage.getItem('admin_locale'))
  }

  function setLocale (locale) {
    const nextLocale = normalize(locale)
    window.localStorage.setItem('admin_locale', nextLocale)
    window.top.postMessage({ type: 'admin-locale-change', locale: nextLocale }, window.location.origin)
    return nextLocale
  }

  function subscribe (callback) {
    const handleStorage = event => {
      if (event.key === 'admin_locale') callback(normalize(event.newValue))
    }
    const handleMessage = event => {
      if (event.origin === window.location.origin && event.data?.type === 'admin-locale-change') {
        callback(normalize(event.data.locale))
      }
    }
    window.addEventListener('storage', handleStorage)
    window.addEventListener('message', handleMessage)
    return () => {
      window.removeEventListener('storage', handleStorage)
      window.removeEventListener('message', handleMessage)
    }
  }

  window.adminI18n = { getLocale, messages, setLocale, subscribe }
})()
