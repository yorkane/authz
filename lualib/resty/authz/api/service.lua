-- Stable API service facade. Domain behavior lives in api/services/* while
-- router and guard contracts remain unchanged.

local applications = require "resty.authz.api.services.applications"
local api_keys = require "resty.authz.api.services.api_keys"
local common = require "resty.authz.api.common"
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
}

return _M
