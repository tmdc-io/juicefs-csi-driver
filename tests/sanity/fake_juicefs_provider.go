/*
Copyright 2018 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package sanity

import (
	"context"
	"github.com/juicedata/juicefs-csi-driver/pkg/config"
	"path/filepath"

	"github.com/juicedata/juicefs-csi-driver/pkg/juicefs"
	"k8s.io/utils/mount"
)

type fakeJfs struct {
	basePath string
	volumes  map[string]string
}

type fakeJfsProvider struct {
	mount.FakeMounter
	fs map[string]fakeJfs
}

func (j *fakeJfsProvider) Settings(ctx context.Context, volumeID string, secrets, volCtx map[string]string, options []string) (*config.JfsSetting, error) {
	return nil, nil
}

func (j *fakeJfsProvider) GetJfsVolUUID(ctx context.Context, name string) (string, error) {
	return "", nil
}

func (j *fakeJfsProvider) JfsCreateVol(ctx context.Context, volumeID string, subPath string, secrets, volCtx map[string]string) error {
	return nil
}

func (j *fakeJfsProvider) JfsDeleteVol(ctx context.Context, volumeID string, target string, secrets, volCtx map[string]string) error {
	return nil
}

func (j *fakeJfsProvider) JfsMount(ctx context.Context, volumeID string, target string, secrets, volCtx map[string]string, options []string) (juicefs.Jfs, error) {
	jfsName := "fake"
	fs, ok := j.fs[jfsName]

	if ok {
		return &fs, nil
	}

	fs = fakeJfs{
		basePath: "/jfs/fake",
		volumes:  map[string]string{},
	}

	j.fs[jfsName] = fs
	return &fs, nil
}

func (j *fakeJfsProvider) JfsCleanupMountPoint(ctx context.Context, mountPath string) error {
	return nil
}

func (j *fakeJfsProvider) JfsUnmount(ctx context.Context, volumeId, mountPath string) error {
	return nil
}

func newFakeJfsProvider() *fakeJfsProvider {
	return &fakeJfsProvider{
		fs: map[string]fakeJfs{},
	}
}

func (fs *fakeJfs) CreateVol(ctx context.Context, name, subPath string) (string, error) {
	_, ok := fs.volumes[name]

	if !ok {
		vol := filepath.Join(fs.basePath, name)
		fs.volumes[name] = vol
		return vol, nil
	}

	return fs.volumes[name], nil
}

func (fs *fakeJfs) GetBasePath() string {
	return fs.basePath
}

func (fs *fakeJfs) BindTarget(ctx context.Context, bindSource, target string) error {
	return nil
}
