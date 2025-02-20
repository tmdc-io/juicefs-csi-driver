# Copyright 2018 The Kubernetes Authors.
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

IMAGE?=juicedata/juicefs-csi-driver
REGISTRY?=docker.io
TARGETARCH?=amd64
FUSE_IMAGE=juicedata/juicefs-fuse
JUICEFS_IMAGE?=juicedata/mount
VERSION=$(shell git describe --tags --match 'v*' --always --dirty)
GIT_BRANCH?=$(shell git rev-parse --abbrev-ref HEAD)
GIT_COMMIT?=$(shell git rev-parse HEAD)
DEV_TAG=dev-$(shell git describe --always --dirty)
BUILD_DATE?=$(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
PKG=github.com/juicedata/juicefs-csi-driver
LDFLAGS?="-X ${PKG}/pkg/driver.driverVersion=${VERSION} -X ${PKG}/pkg/driver.gitCommit=${GIT_COMMIT} -X ${PKG}/pkg/driver.buildDate=${BUILD_DATE} -s -w"
GO111MODULE=on
IMAGE_VERSION_ANNOTATED=$(IMAGE):$(VERSION)-juicefs$(shell docker run --entrypoint=/usr/bin/juicefs $(IMAGE):$(VERSION) version | cut -d' ' -f3)
JUICEFS_CE_LATEST_VERSION=$(shell curl -fsSL https://api.github.com/repos/juicedata/juicefs/releases/latest | grep tag_name | grep -oE 'v[0-9]+\.[0-9][0-9]*(\.[0-9]+(-[0-9a-z]+)?)?')
JUICEFS_EE_LATEST_VERSION=$(shell curl -sSL https://juicefs.com/static/juicefs -o juicefs-ee && chmod +x juicefs-ee && ./juicefs-ee version | cut -d' ' -f3)
JUICEFS_RELEASE_CHECK_VERSION=${JUICEFS_VERSION}
JFS_CHAN=${JFSCHAN}
JUICEFS_CSI_LATEST_VERSION=$(shell git describe --tags --match 'v*' | grep -oE 'v[0-9]+\.[0-9][0-9]*(\.[0-9]+(-[0-9a-z]+)?)?')
JUICEFS_MOUNT_IMAGE?=$(JUICEFS_IMAGE):$(JUICEFS_CE_LATEST_VERSION)-$(JUICEFS_EE_LATEST_VERSION)
JUICEFS_MOUNT_NIGHTLY_IMAGE?=$(JUICEFS_IMAGE):nightly
JUICEFS_REPO_URL?=https://github.com/juicedata/juicefs
JUICEFS_REPO_REF?=$(JUICEFS_CE_LATEST_VERSION)

GOPROXY=https://goproxy.io
GOPATH=$(shell go env GOPATH)
GOOS=$(shell go env GOOS)
GOBIN=$(shell pwd)/bin

.PHONY: juicefs-csi-driver
juicefs-csi-driver: clean tidy fmt vet compile

compile:
	mkdir -p bin
	CGO_ENABLED=0 GOOS=linux go build -ldflags ${LDFLAGS} -o bin/juicefs-csi-driver ./cmd/

.PHONY: verify
verify:
	./hack/verify-all

.PHONY: test
test:
	go test -v -race -cover ./pkg/... -coverprofile=cov1.out

.PHONY: test-sanity
test-sanity:
	go test -v -cover ./tests/sanity/... -coverprofile=cov2.out

# build nightly image
.PHONY: image-nightly
image-nightly:
	# Build image with newest juicefs-csi-driver and juicefs
	docker build --build-arg TARGETARCH=$(TARGETARCH) \
		--build-arg JUICEFS_MOUNT_IMAGE=$(JUICEFS_MOUNT_NIGHTLY_IMAGE) \
		--build-arg JFSCHAN=$(JFS_CHAN) \
        -t $(IMAGE):nightly -f docker/Dockerfile .

# push nightly image
.PHONY: image-nightly-push
image-nightly-push:
	docker push $(IMAGE):nightly

# build & push nightly image
.PHONY: image-nightly-buildx
image-nightly-buildx:
	# Build image with newest juicefs-csi-driver and juicefs
	docker buildx build -t $(IMAGE):nightly \
		--build-arg JUICEFS_MOUNT_IMAGE=$(JUICEFS_MOUNT_NIGHTLY_IMAGE) \
		--build-arg JFSCHAN=$(JFS_CHAN) \
        -f docker/Dockerfile --platform linux/amd64,linux/arm64 . --push

# build latest image
# deprecated
.PHONY: image-latest
image-latest:
	# Build image with latest stable juicefs-csi-driver and juicefs
	docker build --build-arg JUICEFS_CSI_REPO_REF=$(JUICEFS_CSI_LATEST_VERSION) \
		--build-arg JUICEFS_REPO_REF=$(JUICEFS_CE_LATEST_VERSION) \
		--build-arg JFS_AUTO_UPGRADE=disabled \
		--build-arg TARGETARCH=$(TARGETARCH) \
		-t $(IMAGE):latest -f docker/Dockerfile .

# push latest image
# deprecated
.PHONY: push-latest
push-latest:
	docker tag $(IMAGE):latest $(REGISTRY)/$(IMAGE):latest
	docker push $(REGISTRY)/$(IMAGE):latest

# build dev image
# deprecated
.PHONY: image-branch
image-branch:
	docker build --build-arg TARGETARCH=$(TARGETARCH) -t $(IMAGE):$(GIT_BRANCH) -f docker/Dockerfile .

# push dev image
# deprecated
.PHONY: push-branch
push-branch:
	docker tag $(IMAGE):$(GIT_BRANCH) $(REGISTRY)/$(IMAGE):$(GIT_BRANCH)
	docker push $(REGISTRY)/$(IMAGE):$(GIT_BRANCH)

# build & push csi version image
.PHONY: image-version
image-version:
	docker buildx build -t $(IMAGE):$(VERSION) --build-arg JUICEFS_REPO_REF=$(JUICEFS_CE_LATEST_VERSION) \
		--build-arg JUICEFS_MOUNT_IMAGE=$(JUICEFS_MOUNT_IMAGE) \
		--build-arg=JFS_AUTO_UPGRADE=disabled --platform linux/amd64,linux/arm64 -f docker/Dockerfile . --push

.PHONY: push-version
push-version:
	docker push $(IMAGE):$(VERSION)
	docker tag $(IMAGE):$(VERSION) $(IMAGE_VERSION_ANNOTATED)
	docker push $(IMAGE_VERSION_ANNOTATED)

# build deploy yaml
.PHONY: deploy/k8s.yaml
deploy/k8s.yaml: deploy/kubernetes/release/*.yaml
	echo "# DO NOT EDIT: generated by 'kustomize build'" > $@
	kustomize build deploy/kubernetes/release >> $@
	cp $@ deploy/k8s_before_v1_18.yaml
	sed -i.orig 's@storage.k8s.io/v1@storage.k8s.io/v1beta1@g' deploy/k8s_before_v1_18.yaml

# build webhook yaml
.PHONY: deploy/webhook.yaml
deploy/webhook.yaml: deploy/kubernetes/webhook/*.yaml
	echo "# DO NOT EDIT: generated by 'kustomize build'" > $@
	kustomize build deploy/kubernetes/webhook >> $@
	./hack/update_install_script.sh

.PHONY: deploy
deploy: deploy/k8s.yaml
	kubectl apply -f $<

.PHONY: deploy-delete
uninstall: deploy/k8s.yaml
	kubectl delete -f $<

# build dev image
.PHONY: image-dev
image-dev: juicefs-csi-driver
	docker pull $(IMAGE):nightly
	docker build --build-arg TARGETARCH=$(TARGETARCH) -t $(IMAGE):$(DEV_TAG) -f docker/dev.Dockerfile bin

# push dev image
.PHONY: push-dev
push-dev:
ifeq ("$(DEV_K8S)", "microk8s")
	docker image save -o juicefs-csi-driver-$(DEV_TAG).tar $(IMAGE):$(DEV_TAG)
	sudo microk8s.ctr image import juicefs-csi-driver-$(DEV_TAG).tar
	rm -f juicefs-csi-driver-$(DEV_TAG).tar
else ifeq ("$(DEV_K8S)", "kubeadm")
	docker tag $(IMAGE):$(DEV_TAG) $(DEV_REGISTRY):$(DEV_TAG)
	docker push $(DEV_REGISTRY):$(DEV_TAG)
else
	minikube cache add $(IMAGE):$(DEV_TAG)
endif

# build image for release check
.PHONY: image-release-check
image-release-check:
	# Build image with release juicefs
	echo JUICEFS_RELEASE_CHECK_VERSION=$(JUICEFS_RELEASE_CHECK_VERSION)
	docker build --build-arg JUICEFS_CSI_REPO_REF=master \
        --build-arg JUICEFS_REPO_REF=$(JUICEFS_RELEASE_CHECK_VERSION) \
		--build-arg TARGETARCH=$(TARGETARCH) \
		--build-arg JFSCHAN=$(JFS_CHAN) \
		--build-arg=JFS_AUTO_UPGRADE=disabled \
		--build-arg JUICEFS_MOUNT_IMAGE=$(JUICEFS_IMAGE):$(JUICEFS_RELEASE_CHECK_VERSION)-$(JUICEFS_EE_LATEST_VERSION)-check \
		-t $(IMAGE):$(DEV_TAG) -f docker/Dockerfile .

# push image for release check
.PHONY: image-release-check-push
image-release-check-push:
	docker image save -o juicefs-csi-driver-$(DEV_TAG).tar $(IMAGE):$(DEV_TAG)
	sudo microk8s.ctr image import juicefs-csi-driver-$(DEV_TAG).tar
	rm -f juicefs-csi-driver-$(DEV_TAG).tar
	docker tag $(IMAGE):$(DEV_TAG) $(REGISTRY)/$(IMAGE):$(JUICEFS_RELEASE_CHECK_VERSION)-check
	docker push $(REGISTRY)/$(IMAGE):$(JUICEFS_RELEASE_CHECK_VERSION)-check

# build & push juicefs image for release check
.PHONY: juicefs-image-release-check
juicefs-image-release-check:
	docker build -t $(REGISTRY)/$(JUICEFS_IMAGE):$(JUICEFS_RELEASE_CHECK_VERSION)-$(JUICEFS_EE_LATEST_VERSION)-check \
        --build-arg JUICEFS_REPO_REF=$(JUICEFS_RELEASE_CHECK_VERSION) \
		--build-arg=JFS_AUTO_UPGRADE=disabled -f docker/juicefs.Dockerfile .
	docker push $(REGISTRY)/$(JUICEFS_IMAGE):$(JUICEFS_RELEASE_CHECK_VERSION)-$(JUICEFS_EE_LATEST_VERSION)-check

# build & push image for fluid fuse
.PHONY: fuse-image-version
fuse-image-version:
	docker buildx build -f docker/fuse.Dockerfile -t $(REGISTRY)/$(FUSE_IMAGE):$(JUICEFS_CE_LATEST_VERSION)-$(JUICEFS_EE_LATEST_VERSION) \
        --build-arg JUICEFS_REPO_REF=$(JUICEFS_CE_LATEST_VERSION) \
		--build-arg=JFS_AUTO_UPGRADE=disabled --platform linux/amd64,linux/arm64 . --push

# build & push csi slim image
.PHONY: csi-slim-image-version
csi-slim-image-version:
	docker buildx build -f docker/csi.Dockerfile -t $(REGISTRY)/$(IMAGE):$(VERSION)-slim \
        --build-arg JUICEFS_REPO_REF=$(JUICEFS_CE_LATEST_VERSION) \
        --build-arg JUICEFS_MOUNT_IMAGE=$(JUICEFS_MOUNT_IMAGE) \
		--platform linux/amd64,linux/arm64 . --push

# build & push juicefs image
.PHONY: juicefs-image-version
juicefs-image-version:
	docker buildx build -f docker/juicefs.Dockerfile -t $(REGISTRY)/$(JUICEFS_IMAGE):$(JUICEFS_CE_LATEST_VERSION)-$(JUICEFS_EE_LATEST_VERSION) \
        --build-arg JUICEFS_REPO_REF=$(JUICEFS_CE_LATEST_VERSION) \
		--build-arg=JFS_AUTO_UPGRADE=disabled --platform linux/amd64,linux/arm64 . --push

# build & push juicefs latest image
.PHONY: juicefs-image-latest
juicefs-image-latest:
	docker build -f docker/juicefs.Dockerfile -t $(REGISTRY)/$(JUICEFS_IMAGE):latest \
        --build-arg JUICEFS_REPO_REF=$(JUICEFS_CE_LATEST_VERSION) \
		--build-arg=JFS_AUTO_UPGRADE=disabled .
	docker push $(REGISTRY)/$(JUICEFS_IMAGE):latest

# build & push juicefs nightly image
.PHONY: juicefs-image-nightly
juicefs-image-nightly:
	docker build -f docker/juicefs.Dockerfile -t $(REGISTRY)/$(JUICEFS_MOUNT_NIGHTLY_IMAGE) \
        --build-arg JUICEFS_REPO_REF=main \
		--build-arg JFSCHAN=$(JFS_CHAN) \
		--build-arg=JFS_AUTO_UPGRADE=disabled .
	docker push $(REGISTRY)/$(JUICEFS_MOUNT_NIGHTLY_IMAGE)

# build & push juicefs fuse nightly image
.PHONY: juicefs-fuse-image-nightly
juicefs-fuse-image-nightly:
	docker build -f docker/fuse.Dockerfile -t $(REGISTRY)/$(FUSE_IMAGE):nightly \
        --build-arg JUICEFS_REPO_REF=main \
		--build-arg JFSCHAN=$(JFS_CHAN) \
		--build-arg=JFS_AUTO_UPGRADE=disabled .
	docker push $(REGISTRY)/$(FUSE_IMAGE):nightly

.PHONY: deploy-dev/kustomization.yaml
deploy-dev/kustomization.yaml:
	mkdir -p $(@D)
	touch $@
	cd $(@D); kustomize edit add resource ../deploy/kubernetes/release;
ifeq ("$(DEV_K8S)", "kubeadm")
	cd $(@D); kustomize edit set image juicedata/juicefs-csi-driver=$(DEV_REGISTRY):$(DEV_TAG)
else
	cd $(@D); kustomize edit set image juicedata/juicefs-csi-driver=:$(DEV_TAG)
endif

deploy-dev/k8s.yaml: deploy-dev/kustomization.yaml deploy/kubernetes/release/*.yaml
	echo "# DO NOT EDIT: generated by 'kustomize build $(@D)'" > $@
	kustomize build $(@D) >> $@
	# Add .orig suffix only for compactiblity on macOS
ifeq ("$(DEV_K8S)", "microk8s")
	sed -i 's@/var/lib/kubelet@/var/snap/microk8s/common/var/lib/kubelet@g' $@
endif
ifeq ("$(DEV_K8S)", "kubeadm")
	sed -i.orig 's@juicedata/juicefs-csi-driver.*$$@$(DEV_REGISTRY):$(DEV_TAG)@g' $@
else
	sed -i.orig 's@juicedata/juicefs-csi-driver.*$$@juicedata/juicefs-csi-driver:$(DEV_TAG)@g' $@
endif

.PHONY: deploy-dev
deploy-dev: deploy-dev/k8s.yaml
	kapp deploy --app juicefs-csi-driver --file $<

.PHONY: delete-dev
delete-dev: deploy-dev/k8s.yaml
	kapp delete --app juicefs-csi-driver

.PHONY: install-dev
install-dev: verify test image-dev push-dev deploy-dev/k8s.yaml deploy-dev

bin/mockgen: | bin
	go install github.com/golang/mock/mockgen@v1.5.0

mockgen: bin/mockgen
	./hack/update-gomock

.PHONY: clean
clean:
	rm -rf bin

.PHONY: tidy
tidy:
	go mod tidy

.PHONY: fmt
fmt:
	go fmt ./...

.PHONY: vet
vet:
	go vet ./...

.PHONY: tmdc-image-build
tmdc-image-build: juicefs-csi-driver
	docker build --build-arg TARGETARCH=$(TARGETARCH) -t $(IMAGE):v0.18.1-d1 -f docker/dev.Dockerfile bin

.PHONY: tmdc-image-push
tmdc-image-push: tmdc-image-build
	docker tag $(IMAGE):v0.18.1-d1 rubiklabs/juicefs-csi-driver:v0.18.1-d1
	docker push rubiklabs/juicefs-csi-driver:v0.18.1-d1
