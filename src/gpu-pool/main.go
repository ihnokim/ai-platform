package main

import (
	"context"
	"crypto/tls"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	log.Println("Starting GPU Pool Mutating Webhook...")

	// TLS 인증서 경로 설정
	certPath := os.Getenv("TLS_CERT_FILE")
	keyPath := os.Getenv("TLS_PRIVATE_KEY_FILE")
	port := os.Getenv("WEBHOOK_PORT")

	if certPath == "" {
		certPath = "/etc/certs/tls.crt"
	}
	if keyPath == "" {
		keyPath = "/etc/certs/tls.key"
	}
	if port == "" {
		port = "8443"
	}

	// Webhook 핸들러 생성
	webhook := &KaiGpuPoolWebhook{}

	// HTTP 서버 설정
	mux := http.NewServeMux()
	mux.HandleFunc("/mutate", webhook.Handle)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("OK"))
	})

	server := &http.Server{
		Addr:      fmt.Sprintf(":%s", port),
		Handler:   mux,
		TLSConfig: &tls.Config{},
	}

	// Graceful shutdown 설정
	go func() {
		log.Printf("Starting webhook server on port %s", port)
		if err := server.ListenAndServeTLS(certPath, keyPath); err != nil && err != http.ErrServerClosed {
			log.Fatalf("Failed to start webhook server: %v", err)
		}
	}()

	// 종료 신호 대기
	signalChan := make(chan os.Signal, 1)
	signal.Notify(signalChan, syscall.SIGINT, syscall.SIGTERM)
	<-signalChan

	log.Println("Shutting down webhook server...")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		log.Fatalf("Failed to shutdown server: %v", err)
	}
	log.Println("Webhook server stopped")
}
