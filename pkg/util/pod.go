/*
Copyright 2021 Juicedata Inc

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

package util

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/klog"

	"github.com/juicedata/juicefs-csi-driver/pkg/k8sclient"
)

func IsPodReady(pod *corev1.Pod) bool {
	conditionsTrue := 0
	for _, cond := range pod.Status.Conditions {
		if cond.Status == corev1.ConditionTrue && (cond.Type == corev1.ContainersReady || cond.Type == corev1.PodReady) {
			conditionsTrue++
		}
	}
	return conditionsTrue == 2
}

func containError(statuses []corev1.ContainerStatus) bool {
	for _, status := range statuses {
		if (status.State.Waiting != nil && status.State.Waiting.Reason != "ContainerCreating") ||
			(status.State.Terminated != nil && status.State.Terminated.ExitCode != 0) {
			return true
		}
	}
	return false
}

func IsPodError(pod *corev1.Pod) bool {
	if pod.Status.Phase == corev1.PodFailed || pod.Status.Phase == corev1.PodUnknown {
		return true
	}
	return containError(pod.Status.ContainerStatuses)
}

func IsPodResourceError(pod *corev1.Pod) bool {
	if pod.Status.Phase == corev1.PodFailed {
		if strings.Contains(pod.Status.Reason, "OutOf") {
			return true
		}
		if pod.Status.Reason == "UnexpectedAdmissionError" &&
			strings.Contains(pod.Status.Message, "to reclaim resources") {
			return true
		}
	}
	for _, cond := range pod.Status.Conditions {
		if cond.Status == corev1.ConditionFalse && cond.Type == corev1.PodScheduled && cond.Reason == corev1.PodReasonUnschedulable &&
			(strings.Contains(cond.Message, "Insufficient cpu") || strings.Contains(cond.Message, "Insufficient memory")) {
			return true
		}
	}
	return false
}

func DeleteResourceOfPod(pod *corev1.Pod) {
	for i := range pod.Spec.Containers {
		pod.Spec.Containers[i].Resources.Requests = nil
		pod.Spec.Containers[i].Resources.Limits = nil
	}
}

func IsPodHasResource(pod corev1.Pod) bool {
	for _, cn := range pod.Spec.Containers {
		if len(cn.Resources.Requests) != 0 {
			return true
		}
	}
	return false
}

func GetMountPathOfPod(pod corev1.Pod) (string, string, error) {
	if len(pod.Spec.Containers) == 0 {
		return "", "", fmt.Errorf("pod %v has no container", pod.Name)
	}
	cmd := pod.Spec.Containers[0].Command
	if cmd == nil || len(cmd) < 3 {
		return "", "", fmt.Errorf("get error pod command:%v", cmd)
	}
	sourcePath, volumeId, err := ParseMntPath(cmd[2])
	if err != nil {
		return "", "", err
	}
	return sourcePath, volumeId, nil
}

func RemoveFinalizer(ctx context.Context, client *k8sclient.K8sClient, pod *corev1.Pod, finalizer string) error {
	f := pod.GetFinalizers()
	for i := 0; i < len(f); i++ {
		if f[i] == finalizer {
			f = append(f[:i], f[i+1:]...)
			i--
		}
	}
	payload := []k8sclient.PatchListValue{{
		Op:    "replace",
		Path:  "/metadata/finalizers",
		Value: f,
	}}
	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		klog.Errorf("Parse json error: %v", err)
		return err
	}
	if err := client.PatchPod(ctx, pod, payloadBytes, types.JSONPatchType); err != nil {
		klog.Errorf("Patch pod err:%v", err)
		return err
	}
	return nil
}

func AddPodAnnotation(ctx context.Context, client *k8sclient.K8sClient, pod *corev1.Pod, addAnnotations map[string]string) error {
	payloads := []k8sclient.PatchStringValue{}
	for k, v := range addAnnotations {
		payloads = append(payloads, k8sclient.PatchStringValue{
			Op:    "add",
			Path:  fmt.Sprintf("/metadata/annotations/%s", k),
			Value: v,
		})
	}
	payloadBytes, err := json.Marshal(payloads)
	if err != nil {
		klog.Errorf("Parse json error: %v", err)
		return err
	}
	klog.Infof("AddPodAnnotation: %s", string(payloadBytes))
	if err := client.PatchPod(ctx, pod, payloadBytes, types.JSONPatchType); err != nil {
		klog.Errorf("Patch pod %s error: %v", pod.Name, err)
		return err
	}
	return nil
}

func DelPodAnnotation(ctx context.Context, client *k8sclient.K8sClient, pod *corev1.Pod, delAnnotations []string) error {
	payloads := []k8sclient.PatchDelValue{}
	for _, k := range delAnnotations {
		payloads = append(payloads, k8sclient.PatchDelValue{
			Op:   "remove",
			Path: fmt.Sprintf("/metadata/annotations/%s", k),
		})
	}
	payloadBytes, err := json.Marshal(payloads)
	if err != nil {
		klog.Errorf("Parse json error: %v", err)
		return err
	}
	if err := client.PatchPod(ctx, pod, payloadBytes, types.JSONPatchType); err != nil {
		klog.Errorf("Patch pod %s error: %v", pod.Name, err)
		return err
	}
	return nil
}

func ReplacePodAnnotation(ctx context.Context, client *k8sclient.K8sClient, pod *corev1.Pod, annotation map[string]string) error {
	payload := []k8sclient.PatchMapValue{{
		Op:    "replace",
		Path:  "/metadata/annotations",
		Value: annotation,
	}}
	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		klog.Errorf("Parse json error: %v", err)
		return err
	}
	if err := client.PatchPod(ctx, pod, payloadBytes, types.JSONPatchType); err != nil {
		klog.Errorf("Patch pod %s error: %v", pod.Name, err)
		return err
	}
	return nil
}

func GetAllRefKeys(pod corev1.Pod) map[string]string {
	annos := make(map[string]string)
	for k, v := range pod.Annotations {
		if k == GetReferenceKey(v) {
			annos[k] = v
		}
	}
	return annos
}
