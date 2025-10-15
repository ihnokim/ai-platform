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

// MutatingWebhook represents the webhook server
type MutatingWebhook struct{}

// PatchOperation represents a JSON patch operation
type PatchOperation struct {
	Op    string      `json:"op"`
	Path  string      `json:"path"`
	Value interface{} `json:"value,omitempty"`
}

// Handle processes the admission webhook request
func (w *MutatingWebhook) Handle(rw http.ResponseWriter, req *http.Request) {
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
func (w *MutatingWebhook) mutatePod(req *admissionv1.AdmissionRequest) ([]PatchOperation, error) {
	var pod corev1.Pod
	if err := json.Unmarshal(req.Object.Raw, &pod); err != nil {
		return nil, fmt.Errorf("failed to unmarshal pod: %v", err)
	}

	var patches []PatchOperation

	// annotation에 "inho": "message"가 있는지 확인
	if pod.Annotations != nil && pod.Annotations["inho"] == "message" {
		log.Printf("Found 'inho: message' annotation in pod %s/%s, adding label", req.Namespace, req.Name)

		// labels가 없는 경우 초기화
		if pod.Labels == nil {
			patches = append(patches, PatchOperation{
				Op:   "add",
				Path: "/metadata/labels",
				Value: map[string]string{
					"inho": "hello",
				},
			})
		} else {
			// labels가 있는 경우 추가
			patches = append(patches, PatchOperation{
				Op:    "add",
				Path:  "/metadata/labels/inho",
				Value: "hello",
			})
		}
	}

	return patches, nil
}

// sendErrorResponse sends an error response
func (w *MutatingWebhook) sendErrorResponse(rw http.ResponseWriter, uid types.UID, err error) {
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
