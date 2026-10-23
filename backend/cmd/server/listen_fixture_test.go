package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/bcrypt"
)

// This fixture owns its PostgreSQL cluster, API process, ports and credentials.
// It never reads DATABASE_URL or contacts an existing PostgreSQL/API service.
func listenFixture(t *testing.T) (string, *pgxpool.Pool, string, string) {
	t.Helper()
	if testing.Short() {
		t.Skip("isolated PostgreSQL/process integration is excluded by -short")
	}
	for _, binary := range []string{"initdb", "pg_ctl", "go"} {
		if _, err := exec.LookPath(binary); err != nil {
			t.Fatalf("isolated integration requires %s: %v", binary, err)
		}
	}
	dir := t.TempDir()
	data := filepath.Join(dir, "data")
	run := func(name string, args ...string) {
		t.Helper()
		if out, err := exec.Command(name, args...).CombinedOutput(); err != nil {
			t.Fatalf("owned fixture %s: %v\n%s", name, err, out)
		}
	}
	run("initdb", "-D", data, "--auth=trust", "--username=noikar_fixture", "--no-locale", "-E", "UTF8")
	port := unusedListenPort(t)
	run("pg_ctl", "-D", data, "-l", filepath.Join(dir, "postgres.log"), "-o", fmt.Sprintf("-F -h 127.0.0.1 -p %d -c unix_socket_directories=''", port), "-w", "start")
	t.Cleanup(func() { run("pg_ctl", "-D", data, "-m", "immediate", "-w", "stop") })
	dsn := fmt.Sprintf("postgres://noikar_fixture@127.0.0.1:%d/postgres?sslmode=disable", port)
	db, err := pgxpool.New(context.Background(), dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(db.Close)
	binary := filepath.Join(dir, "noikar-auth-fixture")
	run("go", "build", "-o", binary, ".")
	apiPort := unusedListenPort(t)
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		t.Fatal(err)
	}
	jwtSecret := hex.EncodeToString(secret)
	command := exec.Command(binary)
	command.Env = append(os.Environ(), "DATABASE_URL="+dsn, "JWT_SECRET="+jwtSecret, "PROVISIONER_CREDENTIAL="+jwtSecret, "PORT="+fmt.Sprint(apiPort), "BIND_HOST=127.0.0.1")
	logFile, err := os.Create(filepath.Join(dir, "api.log"))
	if err != nil {
		t.Fatal(err)
	}
	command.Stdout, command.Stderr = logFile, logFile
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = command.Process.Kill(); _ = command.Wait(); _ = logFile.Close() })
	url := fmt.Sprintf("http://127.0.0.1:%d", apiPort)
	client := &http.Client{Timeout: time.Second}
	ready := false
	for deadline := time.Now().Add(10 * time.Second); time.Now().Before(deadline); {
		response, err := client.Get(url + "/api/v1/health")
		if err == nil {
			_ = response.Body.Close()
			ready = response.StatusCode == 200
		}
		if ready {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !ready {
		t.Fatal("owned API did not become healthy; see fixture api.log")
	}
	issue := func(name string) string {
		var id string
		hash, err := bcrypt.GenerateFromPassword([]byte("fixture-only-password"), bcrypt.DefaultCost)
		if err != nil {
			t.Fatal(err)
		}
		if err := db.QueryRow(context.Background(), "INSERT INTO accounts(username,password_hash) VALUES($1,$2) RETURNING id", name, string(hash)).Scan(&id); err != nil {
			t.Fatal(err)
		}
		token, err := (&server{jwtSecret: []byte(jwtSecret)}).signToken(id, name)
		if err != nil {
			t.Fatal(err)
		}
		return token
	}
	return url, db, issue("host-fixture"), issue("guest-fixture")
}

func unusedListenPort(t *testing.T) int {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	_ = listener.Close()
	return port
}

func listenRequest(url, path, bearer, credential string, payload any) (int, map[string]any, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return 0, nil, err
	}
	req, err := http.NewRequest(http.MethodPost, url+path, bytes.NewReader(body))
	if err != nil {
		return 0, nil, err
	}
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	if credential != "" {
		req.Header.Set("X-Room-Credential", credential)
	}
	response, err := (&http.Client{Timeout: 5 * time.Second}).Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(response.Body)
	if err != nil {
		return 0, nil, err
	}
	var result map[string]any
	if response.StatusCode != http.StatusNoContent {
		if err := json.Unmarshal(raw, &result); err != nil {
			return response.StatusCode, nil, err
		}
	}
	return response.StatusCode, result, nil
}

func TestOwnedAuthFixtureStartsWithOnlyDisposableAccounts(t *testing.T) {
	_, db, host, guest := listenFixture(t)
	var count int
	if err := db.QueryRow(context.Background(), "SELECT count(*) FROM accounts").Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 2 || host == "" || guest == "" || host == guest {
		t.Fatal("owned fixture must contain exactly its two fresh account identities")
	}
}
