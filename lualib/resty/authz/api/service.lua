-- Stable API service facade. Domain behavior lives in api/services/* while
-- router and guard contracts remain unchanged.

local applications = require "resty.authz.api.services.applications"
local api_keys = require "resty.authz.api.services.api_keys"
local common = require "resty.authz.api.common"
local s3_configs = require "resty.authz.api.services.s3_configs"
local uploads = require "resty.authz.api.services.uploads"
local store_service = require "resty.authz.api.services.store"
local policies = require "resty.authz.api.services.policies"
local read_models = require "resty.authz.api.services.read_models"
local users = require "resty.authz.api.services.users"
local menu_entries = require "resty.authz.api.services.menu_entries"
local menu_services = require "resty.authz.api.services.menu_services"

local _M = {
    roles_for = common.roles_for,
    has_any_role = common.has_any_role,
    is_admin = common.is_admin,
    is_guest = common.is_guest,

    session_payload = read_models.session,
    list_users = read_models.users,
    authorization = read_models.authorization,
    menu_tree = read_models.menu_tree,
    menu_service_rows = read_models.menu_service_rows,
    applications = applications.list,
    list_api_keys = api_keys.list,

    create_user = users.create,
    update_user = users.update,
    update_remote_user = users.update_remote,
    delete_user = users.delete,
    delete_remote_user = users.delete_remote,
    reset_password = users.reset_password,
    change_password = users.change_password,

    create_application = applications.create,
    update_application = applications.update,
    delete_application = applications.delete,

    create_api_key = api_keys.create,
    update_api_key = api_keys.update,
    rotate_api_key = api_keys.rotate,
    delete_api_key = api_keys.delete,

    create_policy = policies.create,
    update_policy = policies.update,
    delete_policy = policies.delete,

    list_menu_entries = menu_entries.list,
    create_menu_entry = menu_entries.create,
    update_menu_entry = menu_entries.update,
    reorder_menu_entries = menu_entries.reorder,
    delete_menu_entry = menu_entries.delete,
    update_menu_service = menu_services.update,
    reset_menu_service = menu_services.reset,
    reorder_menu_services = menu_services.reorder,

    -- ── 多套存储服务配置（s3_configs 表）：CRUD + 连通性测试 + 设为默认 ──
    -- 门面保持手写 re-export（与上面各域一致，不做动态遍历）：router 只认
    -- service.<name>，改名等于改契约。
    list_s3_configs = s3_configs.list,
    s3_config_summary = s3_configs.summary,
    -- 单项摘要（GET /api/s3 的 data.cfg）：入参是 s3_config_store 选出的 cfg 表。
    s3_config_summary_of = s3_configs.summary_of,
    create_s3_config = s3_configs.create,
    update_s3_config = s3_configs.update,
    delete_s3_config = s3_configs.delete,
    set_default_s3_config = s3_configs.set_default,
    test_s3_config = s3_configs.test,

    -- ── 上传流水（upload_records）：列表 / 手工删除 / 手动清理 ──
    list_uploads = uploads.list,
    delete_upload = uploads.remove,
    cleanup_uploads = uploads.cleanup,
    -- 记账挂线（router 在 S3 写成功后调用；内部 pcall，永不影响本次响应）
    record_s3_writes = uploads.record_writes,
    mark_s3_deleted = uploads.mark_deleted,
    mark_s3_renamed = uploads.mark_renamed,

    -- ── 本机临时保存区（store）：agent 免登录落盘 + 每小时过期清理（复用 upload_records）──
    -- store_put 的第 3 个实参是「字节来源」，调用方必须先取 store_body_source()；
    -- 记账用的来源字符串在 opts.source 里。本层只做 re-export，改名等于改契约。
    store_info = store_service.info,
    store_list = store_service.list,
    store_stat = store_service.stat,
    store_body_source = store_service.body_source,
    store_put = store_service.put,
    store_upload = store_service.upload,
    store_remove = store_service.remove

}

return _M
