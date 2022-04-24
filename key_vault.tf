// Create private KV with access policy
data "azurerm_client_config" "deployer" {}

data "azuread_service_principal" "deployer" {
  count = data.azurerm_client_config.deployer.object_id == "" ? 1 : 0
  application_id = data.azurerm_client_config.deployer.client_id
}


resource "azurerm_key_vault" "kv_prvt" {
  count                      = (local.enable_deployers && !local.prvt_kv_exist) ? 1 : 0
  name                       = local.prvt_kv_name
  resource_group_name        = local.rg_exists ? data.azurerm_resource_group.deployer[0].name : azurerm_resource_group.deployer[0].name
  location                   = local.rg_exists ? data.azurerm_resource_group.deployer[0].location : azurerm_resource_group.deployer[0].location
  tenant_id                  = data.azurerm_client_config.deployer.tenant_id
  soft_delete_retention_days = 7
  purge_protection_enabled   = true

  sku_name = "standard"
  lifecycle {
    ignore_changes = [
      // Ignore changes to object_id
      soft_delete_enabled
    ]
  }
}

// Import an existing private Key Vault
data "azurerm_key_vault" "kv_prvt" {
  count               = (local.enable_deployers && local.prvt_kv_exist) ? 1 : 0
  name                = local.prvt_kv_name
  resource_group_name = local.prvt_kv_rg_name
}

resource "azurerm_key_vault_access_policy" "kv_prvt_msi" {
  count        = (local.enable_deployers && !local.prvt_kv_exist) ? 1 : 0
  key_vault_id = azurerm_key_vault.kv_prvt[0].id

  tenant_id = data.azurerm_client_config.deployer.tenant_id
  object_id = azurerm_user_assigned_identity.deployer.principal_id

  secret_permissions = [
    "Get",
    "List"
  ]
}

// Create user KV with access policy
resource "azurerm_key_vault" "kv_user" {
  count                      = (local.enable_deployers && !local.user_kv_exist) ? 1 : 0
  name                       = local.user_kv_name
  resource_group_name        = local.rg_exists ? data.azurerm_resource_group.deployer[0].name : azurerm_resource_group.deployer[0].name
  location                   = local.rg_exists ? data.azurerm_resource_group.deployer[0].location : azurerm_resource_group.deployer[0].location
  tenant_id                  = data.azurerm_client_config.deployer.tenant_id
  soft_delete_retention_days = 7
  purge_protection_enabled   = true

  sku_name = "standard"
  lifecycle {
    ignore_changes = [
      // Ignore changes to object_id
      soft_delete_enabled
    ]
  }
}

// Import an existing user Key Vault
data "azurerm_key_vault" "kv_user" {
  count               = (local.enable_deployers && local.user_kv_exist) ? 1 : 0
  name                = local.user_kv_name
  resource_group_name = local.user_kv_rg_name
}

resource "azurerm_key_vault_access_policy" "kv_user_msi" {
  count        = (local.enable_deployers && !local.user_kv_exist) ? 1 : 0
  key_vault_id = azurerm_key_vault.kv_user[0].id

  tenant_id = data.azurerm_client_config.deployer.tenant_id
  object_id = azurerm_user_assigned_identity.deployer.principal_id

  secret_permissions = [
    "Get",
    "List",
    "Set",
    "Delete",
    "Recover",
    "Backup",
    "Restore",
    "Purge"
  ]
}

resource "azurerm_key_vault_access_policy" "kv_user_pre_deployer" {
  count        = (local.enable_deployers && !local.user_kv_exist) ? 1 : 0
  key_vault_id = azurerm_key_vault.kv_user[0].id

  tenant_id = data.azurerm_client_config.deployer.tenant_id
  # If running as a normal user use the object ID of the user otherwise use the object_id from AAD
  object_id = data.azurerm_client_config.deployer.object_id != "" ? data.azurerm_client_config.deployer.object_id : data.azuread_service_principal.deployer[0].object_id

  secret_permissions = [
    "Get",
    "List",
    "Set",
    "Delete",
    "Recover",
    "Backup",
    "Restore",
    "Purge"
  ]
}

// Comment out code with users.object_id for the time being.
/*
resource "azurerm_key_vault_access_policy" "kv_user_portal" {
  count        = local.enable_deployers ? length(local.deployer_users_id_list) : 0
  key_vault_id = azurerm_key_vault.kv_user[0].id

  tenant_id = data.azurerm_client_config.deployer.tenant_id
  object_id = local.deployer_users_id_list[count.index]

  secret_permissions = [
    "delete",
    "get",
    "list",
    "set",
  ]
}
*/

// Using TF tls to generate SSH key pair and store in user KV
resource "tls_private_key" "deployer" {
  count = (
    local.enable_deployers
    && local.enable_key
    && !local.key_exist
    && (try(file(var.authentication.path_to_public_key), "") == "")
  ) ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

/*
 To force dependency between kv access policy and secrets. Expected behavior:
 https://github.com/terraform-providers/terraform-provider-azurerm/issues/4971
*/
// If user brings an existing KV, the secrets will be stored in the exsiting KV; if not, the secrets will be stored in a newly generated KV
resource "azurerm_key_vault_secret" "ppk" {
  depends_on   = [azurerm_key_vault_access_policy.kv_user_pre_deployer[0]]
  count        = (local.enable_deployers && local.enable_key && !local.key_exist) ? 1 : 0
  name         = local.ppk_secret_name
  value        = local.private_key
  key_vault_id = local.user_kv_exist ? local.user_key_vault_id : azurerm_key_vault.kv_user[0].id
}

resource "azurerm_key_vault_secret" "pk" {
  depends_on   = [azurerm_key_vault_access_policy.kv_user_pre_deployer[0]]
  count        = (local.enable_deployers && local.enable_key && !local.key_exist) ? 1 : 0
  name         = local.pk_secret_name
  value        = local.public_key
  key_vault_id = local.user_kv_exist ? local.user_key_vault_id : azurerm_key_vault.kv_user[0].id
}

resource "azurerm_key_vault_secret" "username" {
  depends_on   = [azurerm_key_vault_access_policy.kv_user_pre_deployer[0]]
  count        = (local.enable_deployers && !local.username_exist) ? 1 : 0
  name         = local.username_secret_name
  value        = local.username
  key_vault_id = local.user_kv_exist ? local.user_key_vault_id : azurerm_key_vault.kv_user[0].id
}

// Generate random password if password is set as authentication type, and save in KV
resource "random_password" "deployer" {
  count = (
    local.enable_deployers
    && local.enable_password
    && !local.pwd_exist
    && local.input_pwd == null
  ) ? 1 : 0

  length           = 32
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  special          = true
  override_special = "_%@"
}

resource "azurerm_key_vault_secret" "pwd" {
  depends_on   = [azurerm_key_vault_access_policy.kv_user_pre_deployer[0]]
  count        = (local.enable_deployers && local.enable_password && !local.pwd_exist) ? 1 : 0
  name         = local.pwd_secret_name
  value        = local.password
  key_vault_id = local.user_kv_exist ? local.user_key_vault_id : azurerm_key_vault.kv_user[0].id
}

data "azurerm_key_vault_secret" "pk" {
  count        = (local.enable_deployers && local.enable_key && local.key_exist) ? 1 : 0
  name         = local.pk_secret_name
  key_vault_id = local.user_key_vault_id
}

data "azurerm_key_vault_secret" "ppk" {
  count        = (local.enable_deployers && local.enable_key && local.key_exist) ? 1 : 0
  name         = local.ppk_secret_name
  key_vault_id = local.user_key_vault_id
}

data "azurerm_key_vault_secret" "username" {
  count        = (local.enable_deployers && local.username_exist) ? 1 : 0
  name         = local.username_secret_name
  key_vault_id = local.user_key_vault_id
}

data "azurerm_key_vault_secret" "pwd" {
  count        = (local.enable_deployers && local.enable_password && local.pwd_exist) ? 1 : 0
  name         = local.pwd_secret_name
  key_vault_id = local.user_key_vault_id
}
