package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
)

type KaiGpuPoolWebhook struct{}

// Handle processes the admission webhook request
func (w *KaiGpuPoolWebhook) Handle(rw http.ResponseWriter, req *http.Request) {
	log.Printf("Received webhook request: %s %s", req.Method, req.URL.Path)

	// Request body 읽기
	body, err := io.ReadAll(req.Body)
	if err != nil {
		log.Printf("Failed to read request body: %v", err)
		http.Error(rw, "Failed to read request body", http.StatusBadRequest)
		return
	}

	// AdmissionReview 파싱
	var admissionReview admissionv1.AdmissionReview
	if err := json.Unmarshal(body, &admissionReview); err != nil {
		log.Printf("Failed to unmarshal admission review: %v", err)
		http.Error(rw, "Failed to parse admission review", http.StatusBadRequest)
		return
	}

	// AdmissionRequest 처리
	admissionRequest := admissionReview.Request
	if admissionRequest == nil {
		log.Printf("No admission request found")
		http.Error(rw, "No admission request found", http.StatusBadRequest)
		return
	}

	log.Printf("Processing admission request for %s/%s (Kind: %s)", 
		admissionRequest.Namespace, admissionRequest.Name, admissionRequest.Kind.Kind)

	// Pod인 경우에만 처리
	var patches []PatchOperation
	if admissionRequest.Kind.Kind == "Pod" {
		patches, err = w.mutatePod(admissionRequest)
		if err != nil {
			log.Printf("Failed to mutate pod: %v", err)
			w.sendErrorResponse(rw, admissionRequest.UID, err)
			return
		}
	}

	// AdmissionResponse 생성
	admissionResponse := &admissionv1.AdmissionResponse{
		UID:     admissionRequest.UID,
		Allowed: true,
	}

	// Patch가 있는 경우 추가
	if len(patches) > 0 {
		patchBytes, err := json.Marshal(patches)
		if err != nil {
			log.Printf("Failed to marshal patches: %v", err)
			w.sendErrorResponse(rw, admissionRequest.UID, err)
			return
		}

		patchType := admissionv1.PatchTypeJSONPatch
		admissionResponse.Patch = patchBytes
		admissionResponse.PatchType = &patchType

		log.Printf("Applied %d patches to pod %s/%s", len(patches), admissionRequest.Namespace, admissionRequest.Name)
	}

	// AdmissionReview 응답 생성
	responseReview := admissionv1.AdmissionReview{
		TypeMeta: metav1.TypeMeta{
			APIVersion: "admission.k8s.io/v1",
			Kind:       "AdmissionReview",
		},
		Response: admissionResponse,
	}

	// JSON 응답 전송
	rw.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(rw).Encode(responseReview); err != nil {
		log.Printf("Failed to encode response: %v", err)
		http.Error(rw, "Failed to encode response", http.StatusInternalServerError)
	}
}

// mutatePod processes Pod mutation logic
func (w *KaiGpuPoolWebhook) mutatePod(req *admissionv1.AdmissionRequest) ([]PatchOperation, error) {
	var pod corev1.Pod
	if err := json.Unmarshal(req.Object.Raw, &pod); err != nil {
		return nil, fmt.Errorf("failed to unmarshal pod: %v", err)
	}

	var patches []PatchOperation

	// annotation에 "mrxrunway.ai/gpu.pool"이 있는지 확인
	if pod.Annotations != nil {
		if gpuPoolName, exists := pod.Annotations["mrxrunway.ai/gpu.pool"]; exists {
			log.Printf("Found GPU pool annotation '%s' in pod %s/%s", gpuPoolName, req.Namespace, req.Name)
			
			// GPU Pool이 있으면 GPU count도 필수로 있어야 함
			gpuCount, countExists := pod.Annotations["mrxrunway.ai/gpu.count"]
			if !countExists {
				return nil, fmt.Errorf("mrxrunway.ai/gpu.pool annotation requires mrxrunway.ai/gpu.count annotation")
			}
			
			// GPU Pool 이름과 count를 변수에 저장
			log.Printf("GPU Pool Name: %s, GPU Count: %s", gpuPoolName, gpuCount)
			
			// GPU Pool 이름을 KAI Scheduler queue label에 추가
			if pod.Labels == nil {
				// labels가 없는 경우 초기화하면서 추가
				patches = append(patches, PatchOperation{
					Op:   "add",
					Path: "/metadata/labels",
					Value: map[string]string{
						"kai.scheduler/queue": gpuPoolName,
					},
				})
				log.Printf("Added KAI scheduler queue label to pod %s/%s (no existing labels)", req.Namespace, req.Name)
			} else {
				// labels가 있는 경우 개별적으로 추가
				patches = append(patches, PatchOperation{
					Op:    "add",
					Path:  "/metadata/labels/kai.scheduler~1queue",
					Value: gpuPoolName,
				})
				log.Printf("Added KAI scheduler queue label to pod %s/%s", req.Namespace, req.Name)
			}
			
			// GPU Count를 첫 번째 컨테이너의 GPU 리소스 제한에 추가
			if len(pod.Spec.Containers) > 0 {
				// 첫 번째 컨테이너의 resources.limits가 없는 경우 초기화
				if pod.Spec.Containers[0].Resources.Limits == nil {
					patches = append(patches, PatchOperation{
						Op:   "add",
						Path: "/spec/containers/0/resources/limits",
						Value: map[string]string{
							"nvidia.com/gpu": gpuCount,
						},
					})
					log.Printf("Added GPU resource limits to pod %s/%s (no existing limits)", req.Namespace, req.Name)
				} else {
					// limits가 있는 경우 nvidia.com/gpu만 추가
					patches = append(patches, PatchOperation{
						Op:    "add",
						Path:  "/spec/containers/0/resources/limits/nvidia.com~1gpu",
						Value: gpuCount,
					})
					log.Printf("Added GPU resource limit to existing limits in pod %s/%s", req.Namespace, req.Name)
				}
			} else {
				log.Printf("Warning: No containers found in pod %s/%s, skipping GPU resource limit", req.Namespace, req.Name)
			}
		}
	}

	return patches, nil
}

// sendErrorResponse sends an error response
func (w *KaiGpuPoolWebhook) sendErrorResponse(rw http.ResponseWriter, uid types.UID, err error) {
	admissionResponse := &admissionv1.AdmissionResponse{
		UID:     uid,
		Allowed: false,
		Result: &metav1.Status{
			Message: err.Error(),
		},
	}

	responseReview := admissionv1.AdmissionReview{
		TypeMeta: metav1.TypeMeta{
			APIVersion: "admission.k8s.io/v1",
			Kind:       "AdmissionReview",
		},
		Response: admissionResponse,
	}

	rw.Header().Set("Content-Type", "application/json")
	rw.WriteHeader(http.StatusOK) // Webhook은 항상 200을 반환해야 함
	json.NewEncoder(rw).Encode(responseReview)
}
