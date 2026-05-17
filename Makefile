.PHONY: help init plan apply destroy deploy validate fmt lint clean

ENVIRONMENT ?= dev
TF_DIR      := terraform
APP_DIR     := django-app

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ---------------------------------------------------------------------------
# Terraform
# ---------------------------------------------------------------------------
init: ## Initialize Terraform (ENVIRONMENT=dev|staging|prod)
	cd $(TF_DIR) && terraform init \
		-backend-config="key=$(ENVIRONMENT)/terraform.tfstate"
	cd $(TF_DIR) && terraform workspace select $(ENVIRONMENT) || \
		terraform workspace new $(ENVIRONMENT)

plan: ## Run terraform plan
	cd $(TF_DIR) && terraform plan \
		-var-file="environments/$(ENVIRONMENT)/terraform.tfvars" \
		-out=tfplan

apply: ## Apply the saved plan
	cd $(TF_DIR) && terraform apply tfplan

destroy: ## Destroy infrastructure (requires confirmation)
	cd $(TF_DIR) && terraform destroy \
		-var-file="environments/$(ENVIRONMENT)/terraform.tfvars"

fmt: ## Format all Terraform files
	cd $(TF_DIR) && terraform fmt -recursive

lint: ## Validate Terraform configuration
	cd $(TF_DIR) && terraform fmt -check -recursive
	cd $(TF_DIR) && terraform init -backend=false
	cd $(TF_DIR) && terraform validate

# ---------------------------------------------------------------------------
# Django
# ---------------------------------------------------------------------------
django-run: ## Run Django dev server locally
	cd $(APP_DIR) && python manage.py runserver

django-test: ## Run Django tests
	cd $(APP_DIR) && python manage.py test --verbosity=2

django-migrate: ## Run Django migrations
	cd $(APP_DIR) && python manage.py migrate

# ---------------------------------------------------------------------------
# Deployment
# ---------------------------------------------------------------------------
deploy: ## Deploy app to EC2 instances
	./scripts/deploy-app.sh $(ENVIRONMENT)

validate: ## Validate infrastructure health
	./scripts/validate-infra.sh

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
clean: ## Remove local artifacts
	find . -name '*.tfplan' -delete
	find . -name '.terraform' -type d -exec rm -rf {} + 2>/dev/null || true
	find . -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
	find . -name '*.pyc' -delete 2>/dev/null || true
