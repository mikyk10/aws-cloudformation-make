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

init:
	@[ ! -d .cache ] && mkdir .cache ||:
	@[ ! -d bin ] && mkdir bin ||:
	@[ ! -d src ] && mkdir src ||:
	@[ ! -d dist ] && mkdir dist ||:
	@[ ! -f bin/mo ] && curl -sSL https://git.io/get-mo -o bin/mo && chmod +x bin/mo ||:
	@[ ! -e .gitignore ] && echo ".gitignore/\ndist/\nbin/" > .gitignore ||:
	@[ ! -e project ] && echo -e 'PROJECT := default\nSTACKNAME = $${ENV}-$${PROJECT}-$${STACKPART}\nAWS_DEFAULT_PROFILE :=' > project ||:

build: clean $(addprefix run/,$(wildcard src/*.yaml))

clean:
	rm -rf .cache/*
	rm -rf dist/*
	
delete-failed: _set-aws-profile
	$(foreach stack, $(shell ${CLI} cloudformation list-stacks | jq -r '.StackSummaries[] | select(.StackStatus == "CREATE_FAILED" or .StackStatus == "ROLLBACK_IN_PROGRESS" or .StackStatus == "ROLLBACK_COMPLETE") | .StackName'), ${CLI} cloudformation delete-stack --stack-name $(stack) )

create: _check-prerequisites clean _set-aws-profile delete-failed dist/${STACK}.yaml dist/${STACK}.config.json
	${CLI} cloudformation create-stack --template-body file://dist/${STACK}.yaml --cli-input-json file://dist/${STACK}.config.json

update: _check-prerequisites clean _set-aws-profile dist/${STACK}.yaml dist/${STACK}.config.json
	${CLI} cloudformation update-stack --template-body file://dist/${STACK}.yaml --cli-input-json file://dist/${STACK}.config.json

changeset: _check-prerequisites clean _set-aws-profile dist/${STACK}.yaml dist/${STACK}.config.json
	${CLI} cloudformation create-change-set --template-body file://dist/${STACK}.yaml --change-set-name=cs-${TIMESTAMP} --cli-input-json file://dist/${STACK}.config.json

delete: _check-prerequisites clean _set-aws-profile
	${CLI} cloudformation delete-stack --stack-name ${STACKNAME}

test: _check-prerequisites clean dist/${STACK}.yaml _set-aws-profile
	${CLI} cloudformation validate-template --template-body file://dist/${STACK}.yaml 

selfupdate:
	curl -o Makefile https://raw.githubusercontent.com/mnaito/aws-cloudformation-make/master/Makefile

run/src/%.yaml dist/%.yaml: .cache/vars
	./bin/mo src/$(notdir $@) --source=.cache/vars | sed -e 's/<<<</{{/g' | sed -e 's/>>>>/}}/g' > dist/$(notdir $@)

.cache/vars:
	cat src/source.vars src/source.vars.${ENV} > .cache/vars ||:

run/src/%.config.json dist/%.config.json: dist/${STACK}.yaml
	jq -n '{}|.StackName="${STACKNAME}"|.Parameters=[{ParameterKey:"ENV",ParameterValue:"${ENV}"}, {ParameterKey:"ServiceName",ParameterValue:"${ENV}-${PROJECT}"}]|.Tags=[{Key:"ENV",Value:"${ENV}"},{Key:"PROJECT",Value:"${PROJECT}"}]' | \
	jq -s '.[0] * .[1]' <( [ -f stack-config.json ] && cat stack-config.json || echo '{}') - | \
	jq -s 'if(.[0].Parameters?) then .[1].Parameters=[.[].Parameters[]] else . end|if(.[0].Tags?) then .[1].Tags=[.[].Tags[]] else . end|.[0] * .[1]' <( [ -f src/${STACK}.config.json ] && cat src/${STACK}.config.json || echo '{}') - | jq -s '.[0] * .[1]' - <(${CLI} cloudformation validate-template --template-body file://dist/${STACK}.yaml | jq '{Capabilities}|del(.Capabilities|nulls)') > dist/${STACK}.config.json

define update_lambda
	$(eval APP := $(notdir $1))
	(pushd $1 && rm -f ../../../dist/${APP}.zip && zip -r ../../../dist/${APP}.zip . ) && ${CLI} lambda update-function-code --function-name ${APP} --zip-file fileb://dist/${APP}.zip
endef

update-lambda: _set-aws-profile
	$(foreach func,$(wildcard src/lambda/*),$(call update_lambda,$(func)))
	

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
