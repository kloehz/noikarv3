package main

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRenderedListenHostAndIndependentGuest(t *testing.T) {
	if os.Getenv("NOIKAR_RENDERED_TESTS") != "1" {
		t.Skip("native graphical host test requires explicit NOIKAR_RENDERED_TESTS=1")
	}
	godot := os.Getenv("GODOT_BIN")
	if godot == "" {
		t.Fatal("rendered integration requires GODOT_BIN")
	}
	url, _, _, _ := listenFixture(t)
	project, err := filepath.Abs("../../..")
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	rendezvous := filepath.Join(dir, "room.json")
	socket, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	gamePort := socket.LocalAddr().(*net.UDPAddr).Port
	_ = socket.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 55*time.Second)
	defer cancel()
	commands := make([]*exec.Cmd, 0, 2)
	logs := make([]string, 0, 2)
	for _, role := range []string{"host", "guest"} {
		args := []string{"--path", project, "--resolution", "1000x700", "--script", "res://tests/manual/listen_host_probe.gd"}
		if role == "guest" {
			args = append(args, "--", "--client")
		}
		command := exec.CommandContext(ctx, godot, args...)
		command.Env = append(os.Environ(), "NOIKAR_TEST_MODE=0", "NOIKAR_ISOLATED_AUTH_API=1", "NOIKAR_NETFOX_PROFILE=", "NOIKAR_BACKEND_URL="+url, "NOIKAR_FIXTURE_ROLE="+role, "NOIKAR_FIXTURE_RENDEZVOUS="+rendezvous, "NOIKAR_FIXTURE_GAME_PORT="+fmt.Sprint(gamePort))
		path := filepath.Join(dir, role+".log")
		file, err := os.Create(path)
		if err != nil {
			t.Fatal(err)
		}
		command.Stdout, command.Stderr = file, file
		t.Cleanup(func() { _ = file.Close() })
		if err := command.Start(); err != nil {
			t.Fatal(err)
		}
		commands = append(commands, command)
		logs = append(logs, path)
	}
	failed := false
	for index, command := range commands {
		err := command.Wait()
		output, _ := os.ReadFile(logs[index])
		text := string(output)
		if strings.Contains(text, "fixture-only-password") || strings.Contains(text, `Bearer eyJ`) {
			t.Fatal("credential leaked in gameplay integration output; logs suppressed")
		}
		if err != nil || strings.Contains(text, "ERROR:") || !strings.Contains(text, `"ok":true`) {
			t.Logf("owned participant %d err=%v\n%s", index, err, text)
			failed = true
		}
	}
	if failed {
		t.Fatal("rendered host/independent guest integration failed")
	}
	t.Log("Rendered host and independent guest passed real login, teams, selection, spawn, movement, attack and host-departure menu cleanup")
}
