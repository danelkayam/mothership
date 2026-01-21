CARRIERS ?= $(shell yq -r '.fleet.carriers | keys | .[]' mothership.yaml)
SHIPS ?= $(shell yq -r '.fleet.ships | keys | .[]' mothership.yaml)

BUILD_DIR := $(CURDIR)/build
COMMON_DIR := $(CURDIR)/common
FLEET_DIR := $(CURDIR)/fleet

.PHONY: build clean deploy update prune

build:  $(SHIPS:%=build-%)
clean: $(SHIPS:%=clean-%)
deploy: $(SHIPS:%=deploy-%)
update: $(SHIPS:%=update-%)
prune: $(SHIPS:%=prune-%)

build-%: SHIP = $*
build-%: CARRIER = $(shell yq -r '.fleet.ships["$(SHIP)"].carrier' mothership.yaml)
build-%: DOMAIN = $(shell yq -r '.fleet.carriers["$(CARRIER)"].domain' mothership.yaml)
build-%: HOST = $(SHIP).$(DOMAIN)
build-%:
	@if [ -z "$(filter $(SHIP),$(SHIPS))" ]; then \
		echo "⚠️ Unknown ship: $(SHIP)"; \
		exit 2; \
	fi

	@if [ -z "$(filter $(CARRIER),$(CARRIERS))" ]; then \
		echo "⚠️ Unknown carrier: $(CARRIER)"; \
		exit 2; \
	fi

	@if [ -z "$(DOMAIN)" ]; then \
		echo "⚠️ No domain defined for carrier: $(CARRIER)"; \
		exit 2; \
	fi

	@echo "🏗️ Building $(SHIP) ..."
	@rm -rf $(BUILD_DIR)/$(SHIP) && mkdir -p $(BUILD_DIR)/$(SHIP)
	@cp -R $(COMMON_DIR)/* $(BUILD_DIR)/$(SHIP)/
	@cp -R $(FLEET_DIR)/$(SHIP)/* $(BUILD_DIR)/$(SHIP)/
	@sed -i 's/{{HOST}}/$(HOST)/g' $(BUILD_DIR)/$(SHIP)/common.yaml
	@echo "🏗️ Building $(SHIP) ... DONE"

clean-%: SHIP = $*
clean-%:
	@echo "🧹 Cleaning $(SHIP) ..."
	@rm -rf $(BUILD_DIR)/$(SHIP)
	@echo "🧹 Cleaning $(SHIP) ... DONE"

deploy-%: SHIP = $*
deploy-%: CARRIER = $(shell yq -r '.fleet.ships["$(SHIP)"].carrier' mothership.yaml)
deploy-%: DOMAIN = $(shell yq -r '.fleet.carriers["$(CARRIER)"].domain' mothership.yaml)
deploy-%: USER = $(shell yq -r '.fleet.carriers["$(CARRIER)"].user' mothership.yaml)
deploy-%: HOST = $(SHIP).$(DOMAIN)
deploy-%: build-%
	@if [ -z "$(filter $(SHIP),$(SHIPS))" ]; then \
		echo "⚠️ Unknown ship: $(SHIP)"; \
		exit 2; \
	fi

	@if [ -z "$(filter $(CARRIER),$(CARRIERS))" ]; then \
		echo "⚠️ Unknown carrier: $(CARRIER)"; \
		exit 2; \
	fi

	@if [ -z "$(DOMAIN)" ]; then \
		echo "⚠️ No domain defined for carrier: $(CARRIER)"; \
		exit 2; \
	fi

	@if [ -z "$(USER)" ]; then \
		echo "⚠️ No user defined for carrier: $(CARRIER)"; \
		exit 2; \
	fi

	@echo "🚀 Deploying $(SHIP) to $(USER)@$(HOST)"
	ssh $(USER)@$(HOST) -t mkdir -p $(SHIP)
	rsync -avz --delete \
		--exclude='.git/' \
		--exclude='.gitignore' \
		--exclude='.gitkeep' \
		--exclude='data' \
		$(BUILD_DIR)/$(SHIP)/ $(USER)@$(HOST):$(SHIP)/
	ssh $(USER)@$(HOST) -t docker compose -f $(SHIP)/compose.yaml \
		up -d --build --remove-orphans --force-recreate
	@echo "🚀 Deploying $(SHIP) to $(USER)@$(HOST) ... DONE"

update-%: SHIP = $*
update-%: CARRIER = $(shell yq -r '.fleet.ships["$(SHIP)"].carrier' mothership.yaml)
update-%: DOMAIN = $(shell yq -r '.fleet.carriers["$(CARRIER)"].domain' mothership.yaml)
update-%: USER = $(shell yq -r '.fleet.carriers["$(CARRIER)"].user' mothership.yaml)
update-%: HOST = $(SHIP).$(DOMAIN)
update-%:
	@if [ -z "$(filter $(SHIP),$(SHIPS))" ]; then \
		echo "⚠️ Unknown ship: $(SHIP)"; \
		exit 2; \
	fi

	@if [ -z "$(filter $(CARRIER),$(CARRIERS))" ]; then \
		echo "⚠️ Unknown carrier: $(CARRIER)"; \
		exit 2; \
	fi

	@if [ -z "$(DOMAIN)" ]; then \
		echo "⚠️ No domain defined for carrier: $(CARRIER)"; \
		exit 2; \
	fi

	@if [ -z "$(USER)" ]; then \
		echo "⚠️ No user defined for carrier: $(CARRIER)"; \
		exit 2; \
	fi

	@echo "♻️ Updating $(SHIP) on $(USER)@$(HOST)"
	ssh $(USER)@$(HOST) -t docker compose -f $(SHIP)/compose.yaml \
		pull
	ssh $(USER)@$(HOST) -t docker compose -f $(SHIP)/compose.yaml \
		up -d --build --remove-orphans --force-recreate
	@echo "♻️ Updating $(SHIP) on $(USER)@$(HOST) ... DONE"

prune-%: SHIP = $*
prune-%: CARRIER = $(shell yq -r '.fleet.ships["$(SHIP)"].carrier' mothership.yaml)
prune-%: DOMAIN = $(shell yq -r '.fleet.carriers["$(CARRIER)"].domain' mothership.yaml)
prune-%: USER = $(shell yq -r '.fleet.carriers["$(CARRIER)"].user' mothership.yaml)
prune-%: HOST = $(SHIP).$(DOMAIN)
prune-%:
	@echo "🪓 Pruning $(SHIP) on $(USER)@$(HOST)"
	ssh $(USER)@$(HOST) -t docker system prune --all --volumes -f
	@echo "🪓 Pruning $(SHIP) on $(USER)@$(HOST) ... DONE"