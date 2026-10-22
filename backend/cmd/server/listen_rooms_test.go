package main

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"
)

func TestListenRoomsWithIsolatedPostgres(t *testing.T) {
	url, db, hostToken, guestToken := listenFixture(t)
	call := func(path, bearer, credential string, payload any, want int) map[string]any {
		t.Helper()
		status, data, err := listenRequest(url, path, bearer, credential, payload)
		if err != nil || status != want {
			t.Fatalf("%s status=%d want=%d err=%v", path, status, want, err)
		}
		encoded, _ := json.Marshal(data)
		for _, forbidden := range []string{hostToken, guestToken, "password", "world_server", "provisioner", "access_token", `"token"`} {
			if strings.Contains(string(encoded), forbidden) {
				t.Fatalf("%s leaked forbidden account/server material", path)
			}
		}
		return data
	}
	create := func() (string, string) {
		t.Helper()
		data := call("/api/v1/listen-rooms", hostToken, "", map[string]string{"session_id": "session-fixture"}, 201)
		room, _ := data["room_id"].(string)
		credential, _ := data["room_credential"].(string)
		if room == "" || len(credential) < 32 {
			t.Fatal("missing room binding or opaque scoped credential")
		}
		identity, ok := data["host_identity"].(map[string]any)
		if !ok || identity["username"] != "host-fixture" || identity["account_id"] == "" {
			t.Fatal("host identity did not come from authenticated local account")
		}
		return room, credential
	}
	room, credential := create()
	otherRoom, otherCredential := create()
	base := "/api/v1/listen-rooms/" + room
	ticket := func() string {
		t.Helper()
		data := call(base+"/tickets", guestToken, "", nil, 201)
		value, _ := data["ticket"].(string)
		if len(value) < 32 {
			t.Fatal("ticket must be a cryptographically opaque handle")
		}
		return value
	}
	t.Run("account bearer required for create and tickets", func(t *testing.T) {
		call("/api/v1/listen-rooms", "", "", map[string]string{"session_id": "session"}, 401)
		call(base+"/tickets", "", credential, nil, 401)
	})
	t.Run("wrong room and credential do not consume valid ticket", func(t *testing.T) {
		value := ticket()
		body := map[string]string{"ticket": value}
		call("/api/v1/listen-rooms/"+otherRoom+"/admissions", "", credential, body, 401)
		call("/api/v1/listen-rooms/"+otherRoom+"/admissions", "", otherCredential, body, 401)
		call(base+"/admissions", "", "wrong-room-credential-with-more-than-32-bytes", body, 401)
		data := call(base+"/admissions", "", credential, body, 200)
		if len(data) != 2 || data["username"] != "guest-fixture" || data["account_id"] == "" {
			t.Fatal("admission must expose only validated account_id/username")
		}
		call(base+"/admissions", "", credential, body, 401)
	})
	t.Run("only hashed expiring proofs persist", func(t *testing.T) {
		value := ticket()
		var rawCount int
		var seconds float64
		if err := db.QueryRow(context.Background(), "SELECT count(*) FROM listen_tickets WHERE ticket_hash=$1", value).Scan(&rawCount); err != nil {
			t.Fatal(err)
		}
		if rawCount != 0 {
			t.Fatal("raw ticket was persisted")
		}
		if err := db.QueryRow(context.Background(), "SELECT EXTRACT(EPOCH FROM MAX(expires_at)-clock_timestamp()) FROM listen_tickets WHERE room_id=$1", room).Scan(&seconds); err != nil {
			t.Fatal(err)
		}
		if seconds < 55 || seconds > 60 {
			t.Fatalf("ticket TTL seconds=%v want approximately 60", seconds)
		}
		if _, err := db.Exec(context.Background(), "UPDATE listen_tickets SET expires_at=clock_timestamp()-INTERVAL '1 second' WHERE room_id=$1", room); err != nil {
			t.Fatal(err)
		}
		call(base+"/admissions", "", credential, map[string]string{"ticket": value}, 401)
	})
	t.Run("concurrent redemption has exactly one winner", func(t *testing.T) {
		value := ticket()
		statuses := make(chan int, 12)
		var workers sync.WaitGroup
		for range 12 {
			workers.Go(func() {
				status, _, err := listenRequest(url, base+"/admissions", "", credential, map[string]string{"ticket": value})
				if err != nil {
					status = 0
				}
				statuses <- status
			})
		}
		workers.Wait()
		close(statuses)
		accepted := 0
		for status := range statuses {
			if status == 200 {
				accepted++
			} else if status != 401 {
				t.Fatalf("unexpected concurrent status %d", status)
			}
		}
		if accepted != 1 {
			t.Fatalf("successful redemptions=%d want exactly one", accepted)
		}
		// No persistent backend roster prevents a permitted rejoin with a fresh proof.
		call(base+"/admissions", "", credential, map[string]string{"ticket": ticket()}, 200)
	})
	t.Run("wrong credential cannot close room and closed room rejects proofs", func(t *testing.T) {
		value := ticket()
		call(base+"/close", "", "wrong-room-credential-with-more-than-32-bytes", nil, 401)
		call(base+"/close", "", credential, nil, 204)
		call(base+"/tickets", guestToken, "", nil, 401)
		call(base+"/admissions", "", credential, map[string]string{"ticket": value}, 401)
	})
	t.Run("expired room cannot issue or redeem", func(t *testing.T) {
		room, credential := create()
		path := "/api/v1/listen-rooms/" + room
		data := call(path+"/tickets", guestToken, "", nil, 201)
		if _, err := db.Exec(context.Background(), "UPDATE listen_rooms SET expires_at=clock_timestamp()-INTERVAL '1 second' WHERE id=$1", room); err != nil {
			t.Fatal(err)
		}
		call(path+"/tickets", guestToken, "", nil, 401)
		call(path+"/admissions", "", credential, map[string]any{"ticket": data["ticket"]}, 401)
	})
}
