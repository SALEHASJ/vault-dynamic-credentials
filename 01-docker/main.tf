terraform {
  required_version = ">= 1.5"
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

provider "docker" {}

resource "docker_image" "vault" {
  name         = "hashicorp/vault:latest"
  keep_locally = true
}

resource "docker_container" "vault" {
  name  = "vault-dev"
  image = docker_image.vault.image_id

  env = [
    "VAULT_DEV_ROOT_TOKEN_ID=myroot",
    "VAULT_DEV_LISTEN_ADDRESS=0.0.0.0:8200"
  ]

  ports {
    internal = 8200
    external = 8200
  }

  volumes {
    host_path      = abspath("${path.module}/vault-data")
    container_path = "/vault/data"
  }
}

output "vault_address" {
  value = "http://localhost:8200"
}

output "vault_token" {
  value = "myroot"
}
