package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/xcrap/nest/daemon/internal/app"
	"github.com/xcrap/nest/daemon/internal/server"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	application, err := app.New()
	if err != nil {
		log.Fatalf("create app: %v", err)
	}
	if err := application.Bootstrap(); err != nil {
		log.Fatalf("bootstrap app: %v", err)
	}

	if err := server.New(application).ListenAndServe(ctx); err != nil {
		log.Fatalf("serve daemon: %v", err)
	}
}
