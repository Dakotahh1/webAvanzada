terraform {
  required_version = ">= 1.5.0"
}

variable "environment" {
  type    = string
  default = "staging"
}

resource "terraform_data" "deploy_frontend" {
  triggers_replace = {
    environment = var.environment
  }

  provisioner "local-exec" {
    command = "rm -rf ../staging && mkdir -p ../staging && cp -r ../frontend/dist/frontend/browser/. ../staging/"
  }
}

output "deployment_path" {
  value = "../staging"
}