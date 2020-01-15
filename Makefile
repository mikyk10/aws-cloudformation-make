# Copyright 2019 Mitsutaka Naito
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

SHELL := /bin/bash
.DEFAULT_GOAL := _check-prerequisites
.PHONY : create update changeset delete delete-failed selfupdate src/%.mo.yaml

ENV := dev
TIMESTAMP := $(shell date +'%Y%m%d-%H%M%S')
CFNEXPORT_PACKAGES3BUCKET := CFNPACKAGES3BUCKET

init:
	@[ ! -d .cache ] && mkdir .cache ||:
	@[ ! -d bin ] && mkdir bin ||:
	@[ ! -d src ] && mkdir src ||:
	@[ ! -d dist ] && mkdir dist ||:
	@[ ! -f bin/mo ] && curl -sSL https://git.io/get-mo -o bin/mo && chmod +x bin/mo ||:
	@[ ! -e .gitignore ] && echo ".gitignore/\ndist/\nbin/" > .gitignore ||:
	@[ ! -e project ] && echo -e 'PROJECT := default\nSTACKNAME = $${ENV}-$${PROJECT}-$${STACKPART}\nAWS_DEFAULT_PROFILE :=' > project ||:

build: clean _check-prerequisites $(addprefix run/,$(wildcard src/*.yaml))

clean:
	rm -rf .cache/*
	rm -rf dist/*
	
create: _check-prerequisites clean _set-aws-profile delete-failed dist/${STACK}.yaml dist/${STACK}.config.json
	$(call exec_create)

update: _check-prerequisites clean _set-aws-profile dist/${STACK}.yaml dist/${STACK}.config.json
	$(call exec_update)

changeset: _check-prerequisites clean _set-aws-profile dist/${STACK}.yaml dist/${STACK}.config.json
	$(call exec_changeset)

package-create: delete-failed _packaging
	$(call exec_create)

package-update: _packaging
	$(call exec_update)

package-changeset: _packaging
	$(call exec_changeset)

delete-failed: _set-aws-profile
	$(foreach stack, $(shell ${CLI} cloudformation list-stacks | jq -r '.StackSummaries[] | select(.StackStatus == "CREATE_FAILED" or .StackStatus == "ROLLBACK_IN_PROGRESS" or .StackStatus == "ROLLBACK_COMPLETE") | .StackName'), ${CLI} cloudformation delete-stack --stack-name $(stack) )
	sleep 3

delete: _check-prerequisites clean _set-aws-profile
	${CLI} cloudformation delete-stack --stack-name ${STACKNAME}

test: _check-prerequisites clean dist/${STACK}.yaml _set-aws-profile
	${CLI} cloudformation validate-template --template-body file://dist/${STACK}.yaml 

selfupdate:
	curl -o Makefile https://raw.githubusercontent.com/mnaito/aws-cloudformation-make/master/Makefile

run/src/%.yaml dist/%.yaml: .cache/vars
	./bin/mo src/$(notdir $@) --allow-function-arguments --source=.cache/vars | sed -e 's/<<<</{{/g' | sed -e 's/>>>>/}}/g' > dist/$(notdir $@)

.cache/vars:
	echo -e "export AWS_PROFILE=${AWS_PROFILE}\nexport ENV=${ENV}\nexport PROJECT=${PROJECT}\nexport SERVICE=${ENV}-${PROJECT}\n" > .cache/vars ||:
	cat src/source.vars >> .cache/vars ||:
	echo >> .cache/vars ||:
	cat src/source.vars.${ENV} >> .cache/vars ||:

run/src/%.config.json dist/%.config.json: dist/${STACK}.yaml
	jq -n '{}|.StackName="${STACKNAME}"|.Tags=[{Key:"ENV",Value:"${ENV}"},{Key:"PROJECT",Value:"${PROJECT}"}]' | \
	jq -s '.[0] * .[1]' <( [ -f stack-config.json ] && cat stack-config.json || echo '{}') - | \
	jq -s 'if(.[0].Parameters?) then .[1].Parameters=[.[0].Parameters[]] else . end|if(.[0].Tags?) then .[1].Tags=[.[0].Tags[]] else . end|.[0] * .[1]' <( [ -f src/${STACK}.config.json ] && cat src/${STACK}.config.json || echo '{}') - | \
	jq -s '.[0] * .[1]' - <(${CLI} cloudformation validate-template --template-body file://dist/${STACK}.yaml | \
	jq '.Capabilities += ["CAPABILITY_AUTO_EXPAND", "CAPABILITY_IAM"]|{Capabilities}') > dist/${STACK}.config.json

define exec_create
	${CLI} cloudformation create-stack --template-body file://dist/${STACK}.yaml --cli-input-json file://dist/${STACK}.config.json
endef

define exec_update
	${CLI} cloudformation update-stack --template-body file://dist/${STACK}.yaml --cli-input-json file://dist/${STACK}.config.json
endef

define exec_changeset
	${CLI} cloudformation create-change-set --template-body file://dist/${STACK}.yaml --change-set-name=cs-${TIMESTAMP} --cli-input-json file://dist/${STACK}.config.json
endef

_packaging: _check-prerequisites clean _set-aws-profile dist/${STACK}.yaml dist/${STACK}.config.json
	$(eval PACKAGES3BUCKET := $(shell ${CLI} cloudformation list-exports | jq -r '.Exports[]|select(.Name|test("${ENV}-${PROJECT}-${CFNEXPORT_PACKAGES3BUCKET}"))|.Value'))
	@$(shell if [ -z "${PACKAGES3BUCKET}" ];then echo 'echo S3 Bucket is missing.;exit 1';fi)
	${CLI} cloudformation package --template-file dist/${STACK}.yaml --s3-bucket ${PACKAGES3BUCKET} --output-template-file dist/${STACK}.yaml --force-upload

_load-config:
	$(eval include project)
	$(eval -include makefile.${ENV})

_set-aws-profile: _load-config
	$(eval AWS_PROFILE = $(shell if [ ! -z "${AWS_PROFILE}" ]; then echo "${AWS_PROFILE}";else if [ ! -z "${AWS_DEFAULT_PROFILE}" ]; then read -e -p 'AWS profile name [${AWS_DEFAULT_PROFILE}]: '; ([[ ! -z "$${REPLY}" ]] && echo $${REPLY} || echo ${AWS_DEFAULT_PROFILE});fi;fi))
	$(eval CLI = aws $(shell if [ ! -z "${AWS_DEFAULT_PROFILE}" ]; then echo '--profile $${AWS_DEFAULT_PROFILE}';fi))

_check-prerequisites: _load-config init
	$(eval STACKPART := $(shell echo '${STACK}' | sed -e 's/^[0-9]*-//g'))

	@which jq > /dev/null || (echo '`jq` is not installed' && exit 1;)
	@(ls src/*.yaml > /dev/null 2>&1) || (echo 'No templates found on src/' && exit 1;)
	@if [ -z "${STACK}" ]; then echo 'STACK={stack name} is not set'; echo; echo -e "Available stacks:\n==="; (for f in $$(ls src/*.yaml);do x=$${f#src/}; echo $${x%.yaml};done); echo; exit 1; fi
