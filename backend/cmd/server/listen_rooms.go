package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"time"

	"github.com/google/uuid"
)

const (
	listenTicketTTL = time.Minute
	listenRoomTTL   = 2 * time.Hour
	listenMigration = `CREATE TABLE IF NOT EXISTS listen_rooms (
    id UUID PRIMARY KEY,
    host_account_id UUID NOT NULL REFERENCES accounts(id),
    session_id TEXT NOT NULL,
    credential_hash TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    closed_at TIMESTAMPTZ
);
CREATE TABLE IF NOT EXISTS listen_tickets (
    ticket_hash TEXT PRIMARY KEY,
    room_id UUID NOT NULL REFERENCES listen_rooms(id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES accounts(id),
    expires_at TIMESTAMPTZ NOT NULL,
    used_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS listen_room_expiry ON listen_rooms(expires_at);
CREATE INDEX IF NOT EXISTS listen_ticket_room ON listen_tickets(room_id);`
)

func (s *server) registerListenRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/listen-rooms", s.createListenRoom)
	mux.HandleFunc("POST /api/v1/listen-rooms/{room_id}/tickets", s.issueListenTicket)
	mux.HandleFunc("POST /api/v1/listen-rooms/{room_id}/admissions", s.redeemListenTicket)
	mux.HandleFunc("POST /api/v1/listen-rooms/{room_id}/close", s.closeListenRoom)
}

// A host gets a room-only credential, never a provisioner/world credential.
func (s *server) createListenRoom(w http.ResponseWriter, r *http.Request) {
	identity, err := s.parseBearerToken(r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid account session")
		return
	}
	var body struct {
		SessionID string `json:"session_id"`
	}
	if !decodeListenBody(w, r, &body) {
		return
	}
	accountID, err := uuid.Parse(identity.AccountID)
	if err != nil || body.SessionID == "" || len(body.SessionID) > 128 {
		writeError(w, http.StatusBadRequest, "invalid session binding")
		return
	}
	credential, err := opaqueListenProof()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not create room")
		return
	}
	roomID := uuid.New()
	var username string
	err = s.db.QueryRow(r.Context(), `WITH created AS (
        INSERT INTO listen_rooms(id,host_account_id,session_id,credential_hash,expires_at)
        VALUES($1,$2,$3,$4,$5) RETURNING host_account_id
    ) SELECT username FROM accounts JOIN created ON accounts.id=created.host_account_id`,
		roomID, accountID, body.SessionID, hashSecret(credential), time.Now().Add(listenRoomTTL)).Scan(&username)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "could not create account-bound room")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{
		"room_id": roomID.String(), "room_credential": credential,
		"host_identity": map[string]string{"account_id": accountID.String(), "username": username},
	})
}

func (s *server) issueListenTicket(w http.ResponseWriter, r *http.Request) {
	identity, err := s.parseBearerToken(r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid account session")
		return
	}
	accountID, accountErr := uuid.Parse(identity.AccountID)
	roomID, roomErr := uuid.Parse(r.PathValue("room_id"))
	if accountErr != nil || roomErr != nil {
		writeError(w, http.StatusUnauthorized, "invalid account or room")
		return
	}
	ticket, err := opaqueListenProof()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not create admission proof")
		return
	}
	tag, err := s.db.Exec(r.Context(), `INSERT INTO listen_tickets(ticket_hash,room_id,account_id,expires_at)
        SELECT $1,id,$3,$4 FROM listen_rooms WHERE id=$2 AND closed_at IS NULL AND expires_at>clock_timestamp()`,
		hashSecret(ticket), roomID, accountID, time.Now().Add(listenTicketTTL))
	if err != nil || tag.RowsAffected() != 1 {
		writeError(w, http.StatusUnauthorized, "room unavailable")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]string{"ticket": ticket})
}

// Lock the room before redeeming. Close uses the same row lock, so redemption
// and room closure have a single database ordering even under concurrent calls.
func (s *server) redeemListenTicket(w http.ResponseWriter, r *http.Request) {
	roomID, ok := listenCredentialRequest(w, r)
	if !ok {
		return
	}
	var body struct {
		Ticket string `json:"ticket"`
	}
	if !decodeListenBody(w, r, &body) {
		return
	}
	if len(body.Ticket) < 32 || len(body.Ticket) > 128 {
		writeError(w, http.StatusUnauthorized, "invalid admission proof")
		return
	}
	tx, err := s.db.Begin(r.Context())
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "admission unavailable")
		return
	}
	defer tx.Rollback(r.Context())
	var id uuid.UUID
	err = tx.QueryRow(r.Context(), `SELECT id FROM listen_rooms WHERE id=$1 AND credential_hash=$2
        AND closed_at IS NULL AND expires_at>clock_timestamp() FOR UPDATE`, roomID, hashSecret(r.Header.Get("X-Room-Credential"))).Scan(&id)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "room unavailable")
		return
	}
	var accountID, username string
	err = tx.QueryRow(r.Context(), `WITH redeemed AS (
        UPDATE listen_tickets SET used_at=clock_timestamp() WHERE ticket_hash=$1 AND room_id=$2
        AND used_at IS NULL AND expires_at>clock_timestamp() RETURNING account_id
    ) SELECT accounts.id::text,accounts.username FROM accounts JOIN redeemed ON accounts.id=redeemed.account_id`, hashSecret(body.Ticket), roomID).Scan(&accountID, &username)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid, expired, or replayed proof")
		return
	}
	if err := tx.Commit(r.Context()); err != nil {
		writeError(w, http.StatusServiceUnavailable, "admission unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"account_id": accountID, "username": username})
}

func (s *server) closeListenRoom(w http.ResponseWriter, r *http.Request) {
	roomID, ok := listenCredentialRequest(w, r)
	if !ok {
		return
	}
	tag, err := s.db.Exec(r.Context(), `UPDATE listen_rooms SET closed_at=COALESCE(closed_at,clock_timestamp())
        WHERE id=$1 AND credential_hash=$2`, roomID, hashSecret(r.Header.Get("X-Room-Credential")))
	if err != nil || tag.RowsAffected() != 1 {
		writeError(w, http.StatusUnauthorized, "invalid room credential")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func listenCredentialRequest(w http.ResponseWriter, r *http.Request) (uuid.UUID, bool) {
	id, err := uuid.Parse(r.PathValue("room_id"))
	credential := r.Header.Get("X-Room-Credential")
	if err != nil || len(credential) < 32 || len(credential) > 128 {
		writeError(w, http.StatusUnauthorized, "invalid room credential")
		return uuid.Nil, false
	}
	return id, true
}

func decodeListenBody(w http.ResponseWriter, r *http.Request, target any) bool {
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request")
		return false
	}
	return true
}

func opaqueListenProof() (string, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(raw), nil
}
