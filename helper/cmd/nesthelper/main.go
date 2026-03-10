package main

import (
	"fmt"
	"os"

	"github.com/xcrap/nest/helper/internal/privileged"
)

func main() {
	if len(os.Args) < 3 {
		usage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "bootstrap":
		if os.Args[2] != "test-domain" {
			usage()
			os.Exit(1)
		}
		exitOnError(privileged.BootstrapTestDomain())
		fmt.Println("test-domain bootstrap complete")
	case "trust":
		if os.Args[2] != "local-ca" {
			usage()
			os.Exit(1)
		}
		exitOnError(privileged.TrustLocalCA())
	default:
		usage()
		os.Exit(1)
	}
}

func usage() {
	fmt.Println("nesthelper commands:")
	fmt.Println("  sudo nesthelper bootstrap test-domain")
	fmt.Println("  sudo nesthelper trust local-ca")
}

func exitOnError(err error) {
	if err == nil {
		return
	}
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
