package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestGodotListenAPIWithIsolatedPostgres(t *testing.T) {
	godot := os.Getenv("GODOT_BIN")
	if godot == "" {
		t.Skip("GODOT_BIN is unset: real Godot HTTP integration not certified")
	}
	url, db, hostToken, guestToken := listenFixture(t)
	var hostID, guestID string
	if err := db.QueryRow(context.Background(), "SELECT id::text FROM accounts WHERE username='host-fixture'").Scan(&hostID); err != nil {
		t.Fatal(err)
	}
	if err := db.QueryRow(context.Background(), "SELECT id::text FROM accounts WHERE username='guest-fixture'").Scan(&guestID); err != nil {
		t.Fatal(err)
	}
	project, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, godot, "--headless", "--path", project, "--script", "res://tests/manual/listen_api_probe.gd")
	command.Env = append(os.Environ(), "NOIKAR_TEST_MODE=1", "NOIKAR_ISOLATED_AUTH_API=1", "NOIKAR_NETFOX_PROFILE=", "NOIKAR_BACKEND_URL="+url,
		"NOIKAR_FIXTURE_HOST_TOKEN="+hostToken, "NOIKAR_FIXTURE_HOST_ID="+hostID, "NOIKAR_FIXTURE_GUEST_TOKEN="+guestToken, "NOIKAR_FIXTURE_GUEST_ID="+guestID)
	output, err := command.CombinedOutput()
	text := string(output)
	if strings.Contains(text, hostToken) || strings.Contains(text, guestToken) {
		t.Fatal("Godot integration leaked account material; output suppressed")
	}
	if err != nil || strings.Contains(text, "ERROR:") || !strings.Contains(text, `"ok":true`) {
		t.Fatalf("Godot integration err=%v\n%s", err, text)
	}
	t.Log("Godot real-HTTP/PostgreSQL create, issue, redeem, replay, close and retained-login probe passed")
}

func TestGodotRejectsCredentialRedirects(t *testing.T) {
	if testing.Short() {
		t.Skip("Godot process integration excluded by -short")
	}
	godot := os.Getenv("GODOT_BIN")
	if godot == "" {
		t.Skip("GODOT_BIN is unset: redirect credential boundary not certified")
	}
	var hits atomic.Int32
	trap := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		writeJSON(w, 200, map[string]bool{"received": true})
	}))
	defer trap.Close()
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, trap.URL, http.StatusTemporaryRedirect)
	}))
	defer origin.Close()
	project, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, godot, "--headless", "--path", project, "--script", "res://tests/manual/listen_api_probe.gd")
	command.Env = append(os.Environ(), "NOIKAR_TEST_MODE=1", "NOIKAR_ISOLATED_AUTH_API=1", "NOIKAR_NETFOX_PROFILE=", "NOIKAR_BACKEND_URL="+origin.URL, "NOIKAR_FIXTURE_REDIRECT_PROBE=1")
	output, err := command.CombinedOutput()
	if err != nil || hits.Load() != 0 || strings.Contains(string(output), "ERROR:") {
		t.Fatalf("credential redirect boundary: err=%v forwarded_requests=%d\n%s", err, hits.Load(), output)
	}
}
