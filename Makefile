CONFIG_FILE := mothership.yaml
CARRIERS ?= $(shell yq -r '.fleet.carriers | keys | .[]' $(CONFIG_FILE))
SHIPS ?= $(shell yq -r '.fleet.ships | keys | .[]' $(CONFIG_FILE))

BUILD_DIR := $(CURDIR)/build
COMMON_DIR := $(CURDIR)/common
FLEET_DIR := $(CURDIR)/fleet

.PHONY: build clean sync launch deploy update prune

build:  $(SHIPS:%=build-%)
clean: $(SHIPS:%=clean-%)
sync: $(SHIPS:%=sync-%)
launch: $(SHIPS:%=launch-%)
deploy: $(SHIPS:%=deploy-%)
update: $(SHIPS:%=update-%)
prune: $(SHIPS:%=prune-%)

define validate_ship_context
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
endef

build-%: SHIP = $*
build-%: CARRIER = $(shell yq -r '.fleet.ships["$(SHIP)"].carrier' $(CONFIG_FILE))
build-%: DOMAIN = $(shell yq -r '.fleet.carriers["$(CARRIER)"].domain' $(CONFIG_FILE))
build-%: USER = $(shell yq -r '.fleet.carriers["$(CARRIER)"].user' $(CONFIG_FILE))
build-%: HOST = $(SHIP).$(DOMAIN)
build-%:
	$(validate_ship_context)

	@echo "🏗️ Building $(SHIP) ..."
	@rm -rf $(BUILD_DIR)/$(SHIP) && mkdir -p $(BUILD_DIR)/$(SHIP)
	@cp -R $(COMMON_DIR)/. $(BUILD_DIR)/$(SHIP)/
	@cp -R $(FLEET_DIR)/$(SHIP)/. $(BUILD_DIR)/$(SHIP)/
	@sed -i 's/{{HOST}}/$(HOST)/g' $(BUILD_DIR)/$(SHIP)/common.yaml
	@echo "🏗️ Building $(SHIP) ... DONE"

clean-%: SHIP = $*
clean-%:
	@echo "🧹 Cleaning $(SHIP) ..."
	@rm -rf $(BUILD_DIR)/$(SHIP)
	@echo "🧹 Cleaning $(SHIP) ... DONE"

sync-%: SHIP = $*
sync-%: CARRIER = $(shell yq -r '.fleet.ships["$(SHIP)"].carrier' $(CONFIG_FILE))
sync-%: DOMAIN = $(shell yq -r '.fleet.carriers["$(CARRIER)"].domain' $(CONFIG_FILE))
sync-%: USER = $(shell yq -r '.fleet.carriers["$(CARRIER)"].user' $(CONFIG_FILE))
sync-%: HOST = $(SHIP).$(DOMAIN)
sync-%: build-%
	$(validate_ship_context)

	@echo "🛰️ Syncing $(SHIP) to $(USER)@$(HOST)"
	@if [ ! -f "$(BUILD_DIR)/$(SHIP)/.syncignore" ]; then \
		touch "$(BUILD_DIR)/$(SHIP)/.syncignore"; \
	fi

	ssh $(USER)@$(HOST) -t mkdir -p $(SHIP)
	rsync -avz --delete \
		--exclude='.git/' \
		--exclude='.gitignore' \
		--exclude='.gitkeep' \
		--exclude='.syncignore' \
		--exclude='data' \
		--exclude-from="$(BUILD_DIR)/$(SHIP)/.syncignore" \
		$(BUILD_DIR)/$(SHIP)/ $(USER)@$(HOST):$(SHIP)/
	@echo "🛰️ Syncing $(SHIP) to $(USER)@$(HOST) ... DONE"

launch-%: SHIP = $*
launch-%: CARRIER = $(shell yq -r '.fleet.ships["$(SHIP)"].carrier' $(CONFIG_FILE))
launch-%: DOMAIN = $(shell yq -r '.fleet.carriers["$(CARRIER)"].domain' $(CONFIG_FILE))
launch-%: USER = $(shell yq -r '.fleet.carriers["$(CARRIER)"].user' $(CONFIG_FILE))
launch-%: HOST = $(SHIP).$(DOMAIN)
launch-%:
	$(validate_ship_context)

	@echo "🚀 Launching $(SHIP) on $(USER)@$(HOST)"
	ssh $(USER)@$(HOST) -t docker compose -f $(SHIP)/compose.yaml \
		up -d --build --remove-orphans --force-recreate
	@echo "🚀 Launching $(SHIP) on $(USER)@$(HOST) ... DONE"

deploy-%: SHIP = $*
deploy-%: CARRIER = $(shell yq -r '.fleet.ships["$(SHIP)"].carrier' $(CONFIG_FILE))
deploy-%: DOMAIN = $(shell yq -r '.fleet.carriers["$(CARRIER)"].domain' $(CONFIG_FILE))
deploy-%: USER = $(shell yq -r '.fleet.carriers["$(CARRIER)"].user' $(CONFIG_FILE))
deploy-%: HOST = $(SHIP).$(DOMAIN)
deploy-%: sync-% launch-%
	$(validate_ship_context)

	@echo "🛸 Deploying $(SHIP) to $(USER)@$(HOST)"
	@echo "🛸 Deploying $(SHIP) to $(USER)@$(HOST) ... DONE"

update-%: SHIP = $*
update-%: CARRIER = $(shell yq -r '.fleet.ships["$(SHIP)"].carrier' $(CONFIG_FILE))
update-%: DOMAIN = $(shell yq -r '.fleet.carriers["$(CARRIER)"].domain' $(CONFIG_FILE))
update-%: USER = $(shell yq -r '.fleet.carriers["$(CARRIER)"].user' $(CONFIG_FILE))
update-%: HOST = $(SHIP).$(DOMAIN)
update-%:
	$(validate_ship_context)

	@echo "♻️ Updating $(SHIP) on $(USER)@$(HOST)"
	ssh $(USER)@$(HOST) -t docker compose -f $(SHIP)/compose.yaml \
		pull
	ssh $(USER)@$(HOST) -t docker compose -f $(SHIP)/compose.yaml \
		up -d --build --remove-orphans --force-recreate
	@echo "♻️ Updating $(SHIP) on $(USER)@$(HOST) ... DONE"

prune-%: SHIP = $*
prune-%: CARRIER = $(shell yq -r '.fleet.ships["$(SHIP)"].carrier' $(CONFIG_FILE))
prune-%: DOMAIN = $(shell yq -r '.fleet.carriers["$(CARRIER)"].domain' $(CONFIG_FILE))
prune-%: USER = $(shell yq -r '.fleet.carriers["$(CARRIER)"].user' $(CONFIG_FILE))
prune-%: HOST = $(SHIP).$(DOMAIN)
prune-%:
	$(validate_ship_context)

	@echo "🪓 Pruning $(SHIP) on $(USER)@$(HOST)"
	ssh $(USER)@$(HOST) -t docker system prune -af
	@echo "🪓 Pruning $(SHIP) on $(USER)@$(HOST) ... DONE"