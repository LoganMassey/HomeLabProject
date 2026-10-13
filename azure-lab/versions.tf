terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  # azurerm 4.x requires an explicit subscription id.
  # Set it here via terraform.tfvars, or export ARM_SUBSCRIPTION_ID instead.
  subscription_id = var.subscription_id

  features {
    # Defender for Cloud auto-provisions OperationsManagement/solutions onto the
    # Log Analytics workspace. Those are not in Terraform state, so a destroy
    # leaves the resource group non-empty and the delete fails. This lets
    # Terraform delete the group anyway. Acceptable here because Terraform owns
    # everything in lab-rg; a bad idea in a shared subscription.
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
}
