SHIPS ?= $(shell yq '.fleet.ships.[].name' mothership.yaml)
USER = $(shell yq '.fleet.user' mothership.yaml)
DOMAIN = $(shell yq '.fleet.domain' mothership.yaml)

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
build-%: HOST = $*.${DOMAIN}
build-%:
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
deploy-%: HOST = $*.${DOMAIN}
deploy-%: build-%
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
update-%: HOST = $*.${DOMAIN}
update-%:
	@echo "♻️ Updating $(SHIP) on $(USER)@$(HOST)"
	ssh $(USER)@$(HOST) -t docker compose -f $(SHIP)/compose.yaml \
		pull
	ssh $(USER)@$(HOST) -t docker compose -f $(SHIP)/compose.yaml \
		up -d --build --remove-orphans --force-recreate
	@echo "♻️ Updating $(SHIP) on $(USER)@$(HOST) ... DONE"

prune-%: SHIP = $*
prune-%: HOST = $*.${DOMAIN}
prune-%:
	@echo "🪓 Pruning $(SHIP) on $(USER)@$(HOST)"
	ssh $(USER)@$(HOST) -t docker system prune --all --volumes -f
	@echo "🪓 Pruning $(SHIP) on $(USER)@$(HOST) ... DONE"