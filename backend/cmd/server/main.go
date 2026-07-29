package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/crypto/bcrypt"
)

const (
	accessTokenTTL = time.Hour
	roomCreatorTicketTTL = 2 * time.Minute
	minPasswordLen = 8
	minSecretLen   = 32
	authMigration  = `CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE TABLE IF NOT EXISTS accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE TABLE IF NOT EXISTS room_creator_tickets (
    ticket_hash TEXT PRIMARY KEY,
    account_id UUID NOT NULL REFERENCES accounts(id),
    provision_instance_id UUID,
    world_credential_hash TEXT,
    expires_at TIMESTAMPTZ NOT NULL,
    used_at TIMESTAMPTZ
);
ALTER TABLE room_creator_tickets DROP CONSTRAINT IF EXISTS room_creator_tickets_pkey;
ALTER TABLE room_creator_tickets DROP COLUMN IF EXISTS ticket_id;
ALTER TABLE room_creator_tickets ADD COLUMN IF NOT EXISTS ticket_hash TEXT;
ALTER TABLE room_creator_tickets DROP COLUMN IF EXISTS provision_nonce;
ALTER TABLE room_creator_tickets ADD COLUMN IF NOT EXISTS provision_instance_id UUID;
ALTER TABLE room_creator_tickets ADD COLUMN IF NOT EXISTS world_credential_hash TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS room_creator_tickets_ticket_hash_idx ON room_creator_tickets(ticket_hash);`
	roomCreatorTicketBindSQL = `UPDATE room_creator_tickets SET provision_instance_id = $1, world_credential_hash = $2
		WHERE ticket_hash = $3 AND provision_instance_id IS NULL AND used_at IS NULL AND expires_at > NOW()`
	roomCreatorTicketRedeemSQL = `UPDATE room_creator_tickets SET used_at = NOW()
		WHERE ticket_hash = $1 AND provision_instance_id = $2 AND world_credential_hash = $3 AND used_at IS NULL AND expires_at > NOW()
		RETURNING account_id`
)

type config struct {
	address     string
	databaseURL string
	jwtSecret   []byte
	provisionerCredential []byte
}

type server struct {
	db        *pgxpool.Pool
	jwtSecret []byte
	provisionerCredential []byte
}

type roomCreatorTicketResponse struct {
	Ticket string `json:"ticket"`
}

type roomCreatorTicketValidationRequest struct {
	Ticket string `json:"ticket"`
	ProvisionInstanceID string `json:"provision_instance_id"`
}

type roomCreatorTicketBindRequest struct { Ticket string `json:"ticket"`; ProvisionInstanceID string `json:"provision_instance_id"`; WorldServerCredential string `json:"world_server_credential"` }

type credentials struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type claims struct {
	AccountID string `json:"account_id"`
	Username  string `json:"username"`
	jwt.RegisteredClaims
}

type authResponse struct {
	Token     string `json:"token"`
	AccountID string `json:"account_id"`
	Username  string `json:"username"`
}

type errorResponse struct {
	Error string `json:"error"`
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatal(err)
	}

	ctx := context.Background()
	db, err := pgxpool.New(ctx, cfg.databaseURL)
	if err != nil {
		log.Fatalf("configure database pool: %v", err)
	}
	defer db.Close()

	pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	err = db.Ping(pingCtx)
	cancel()
	if err != nil {
		log.Fatalf("connect database: %v", err)
	}
	if _, err := db.Exec(ctx, authMigration); err != nil {
		log.Fatalf("run auth migration: %v", err)
	}

	s := &server{db: db, jwtSecret: cfg.jwtSecret, provisionerCredential: cfg.provisionerCredential}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/health", s.health)
	mux.HandleFunc("POST /api/v1/auth/register", s.register)
	mux.HandleFunc("POST /api/v1/auth/login", s.login)
	mux.HandleFunc("GET /api/v1/auth/me", s.me)
	mux.HandleFunc("POST /api/v1/rooms/creator-ticket", s.issueRoomCreatorTicket)
	mux.HandleFunc("POST /api/v1/rooms/creator-ticket/bind", s.bindRoomCreatorTicket)
	mux.HandleFunc("POST /api/v1/rooms/creator-ticket/validate", s.validateRoomCreatorTicket)

	httpServer := &http.Server{
		Addr:              cfg.address,
		Handler:           withSecurityHeaders(mux),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	log.Printf("Noikar auth API listening on %s", cfg.address)
	log.Fatal(httpServer.ListenAndServe())
}

func loadConfig() (config, error) {
	secret := strings.TrimSpace(os.Getenv("JWT_SECRET"))
	if utf8.RuneCountInString(secret) < minSecretLen {
		return config{}, fmt.Errorf("JWT_SECRET must contain at least %d characters", minSecretLen)
	}
	databaseURL := strings.TrimSpace(os.Getenv("DATABASE_URL"))
	if databaseURL == "" {
		return config{}, errors.New("DATABASE_URL is required")
	}
	address := strings.TrimSpace(os.Getenv("PORT"))
	if address == "" {
		address = "8080"
	}
	provisionerCredential := strings.TrimSpace(os.Getenv("PROVISIONER_CREDENTIAL"))
	if utf8.RuneCountInString(provisionerCredential) < minSecretLen {
		return config{}, fmt.Errorf("PROVISIONER_CREDENTIAL must contain at least %d characters", minSecretLen)
	}
	return config{address: ":" + address, databaseURL: databaseURL, jwtSecret: []byte(secret), provisionerCredential: []byte(provisionerCredential)}, nil
}

func (s *server) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *server) register(w http.ResponseWriter, r *http.Request) {
	creds, ok := decodeCredentials(w, r, true)
	if !ok {
		return
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(creds.Password), bcrypt.DefaultCost)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not create account")
		return
	}

	var accountID uuid.UUID
	err = s.db.QueryRow(r.Context(),
		"INSERT INTO accounts (username, password_hash) VALUES ($1, $2) RETURNING id",
		creds.Username, string(hash),
	).Scan(&accountID)
	if err != nil {
		if isUniqueViolation(err) {
			writeError(w, http.StatusConflict, "username already taken")
			return
		}
		log.Printf("create account: %v", err)
		writeError(w, http.StatusInternalServerError, "could not create account")
		return
	}

	s.respondWithToken(w, http.StatusCreated, accountID, creds.Username)
}

func (s *server) login(w http.ResponseWriter, r *http.Request) {
	creds, ok := decodeCredentials(w, r, false)
	if !ok {
		return
	}

	var accountID uuid.UUID
	var passwordHash string
	err := s.db.QueryRow(r.Context(),
		"SELECT id, password_hash FROM accounts WHERE username = $1", creds.Username,
	).Scan(&accountID, &passwordHash)
	if err != nil || bcrypt.CompareHashAndPassword([]byte(passwordHash), []byte(creds.Password)) != nil {
		writeError(w, http.StatusUnauthorized, "invalid username or password")
		return
	}

	s.respondWithToken(w, http.StatusOK, accountID, creds.Username)
}

func (s *server) me(w http.ResponseWriter, r *http.Request) {
	claims, err := s.parseBearerToken(r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid or expired token")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"account_id": claims.AccountID,
		"username":   claims.Username,
	})
}

func (s *server) issueRoomCreatorTicket(w http.ResponseWriter, r *http.Request) {
	accessClaims, err := s.parseBearerToken(r)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid or expired token")
		return
	}
	ticket, ticketHash, expiresAt, err := newRoomCreatorTicket()
	if err != nil {
		log.Printf("sign room creator ticket: %v", err)
		writeError(w, http.StatusInternalServerError, "could not create room ticket")
		return
	}
	accountID, err := uuid.Parse(accessClaims.AccountID)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid account")
		return
	}
	if _, err := s.db.Exec(r.Context(), "INSERT INTO room_creator_tickets (ticket_hash, account_id, expires_at) VALUES ($1, $2, $3)", ticketHash, accountID, expiresAt); err != nil {
		log.Printf("store room creator ticket: %v", err)
		writeError(w, http.StatusInternalServerError, "could not create room ticket")
		return
	}
	writeJSON(w, http.StatusCreated, roomCreatorTicketResponse{Ticket: ticket})
}

func (s *server) bindRoomCreatorTicket(w http.ResponseWriter, r *http.Request) {
	if !s.validProvisionerCredential(r.Header.Get("X-Provisioner-Credential")) { writeError(w, http.StatusUnauthorized, "invalid provisioner credential"); return }
	var request roomCreatorTicketBindRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&request); err != nil || request.Ticket == "" || !validProvisionInstanceID(request.ProvisionInstanceID) || len(request.WorldServerCredential) < minSecretLen { writeError(w, http.StatusBadRequest, "invalid provision binding"); return }
	tag, err := s.db.Exec(r.Context(), roomCreatorTicketBindSQL, request.ProvisionInstanceID, hashSecret(request.WorldServerCredential), hashRoomCreatorTicket(request.Ticket))
	if err != nil { writeError(w, http.StatusUnauthorized, "invalid room ticket"); return }
	if tag.RowsAffected() != 1 { writeError(w, http.StatusUnauthorized, "invalid room ticket"); return }
	writeJSON(w, http.StatusNoContent, nil)
}

func (s *server) validateRoomCreatorTicket(w http.ResponseWriter, r *http.Request) {
	var request roomCreatorTicketValidationRequest
	worldCredential := r.Header.Get("X-World-Server-Credential")
	if len(worldCredential) < minSecretLen { writeError(w, http.StatusUnauthorized, "invalid world server credential"); return }
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&request); err != nil || request.Ticket == "" || !validProvisionInstanceID(request.ProvisionInstanceID) {
		writeError(w, http.StatusBadRequest, "room ticket is required")
		return
	}
	var validatedAccountID uuid.UUID
	err := s.db.QueryRow(r.Context(), roomCreatorTicketRedeemSQL, hashRoomCreatorTicket(request.Ticket), request.ProvisionInstanceID, hashSecret(worldCredential)).Scan(&validatedAccountID)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "invalid, expired, or replayed room ticket")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"account_id": validatedAccountID.String()})
}

func (s *server) respondWithToken(w http.ResponseWriter, status int, accountID uuid.UUID, username string) {
	token, err := s.signToken(accountID.String(), username)
	if err != nil {
		log.Printf("sign token: %v", err)
		writeError(w, http.StatusInternalServerError, "could not create session")
		return
	}
	writeJSON(w, status, authResponse{Token: token, AccountID: accountID.String(), Username: username})
}

func (s *server) signToken(accountID, username string) (string, error) {
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims{
		AccountID: accountID,
		Username:  username,
		RegisteredClaims: jwt.RegisteredClaims{
			IssuedAt:  jwt.NewNumericDate(time.Now()),
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(accessTokenTTL)),
		},
	}).SignedString(s.jwtSecret)
}

func newRoomCreatorTicket() (string, string, time.Time, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil { return "", "", time.Time{}, err }
	ticket := base64.RawURLEncoding.EncodeToString(raw)
	expiresAt := time.Now().Add(roomCreatorTicketTTL)
	return ticket, hashRoomCreatorTicket(ticket), expiresAt, nil
}

func hashRoomCreatorTicket(ticket string) string {
	sum := sha256.Sum256([]byte(ticket))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

func (s *server) validProvisionerCredential(value string) bool {
	if value == "" || len(s.provisionerCredential) == 0 { return false }
	return subtle.ConstantTimeCompare([]byte(value), s.provisionerCredential) == 1
}

func validProvisionInstanceID(value string) bool { _, err := uuid.Parse(value); return err == nil }
func hashSecret(value string) string { return hashRoomCreatorTicket(value) }

func (s *server) parseBearerToken(r *http.Request) (*claims, error) {
	header := strings.SplitN(r.Header.Get("Authorization"), " ", 2)
	if len(header) != 2 || !strings.EqualFold(header[0], "Bearer") || header[1] == "" {
		return nil, errors.New("missing bearer token")
	}
	parsed, err := jwt.ParseWithClaims(header[1], &claims{}, func(token *jwt.Token) (interface{}, error) {
		if token.Method != jwt.SigningMethodHS256 {
			return nil, errors.New("unexpected signing method")
		}
		return s.jwtSecret, nil
	})
	if err != nil || !parsed.Valid {
		return nil, errors.New("invalid token")
	}
	result, ok := parsed.Claims.(*claims)
	if !ok || result.AccountID == "" || result.Username == "" {
		return nil, errors.New("invalid claims")
	}
	return result, nil
}

func decodeCredentials(w http.ResponseWriter, r *http.Request, registering bool) (credentials, bool) {
	var creds credentials
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&creds); err != nil {
		writeError(w, http.StatusBadRequest, "invalid request")
		return credentials{}, false
	}
	creds.Username = strings.ToLower(strings.TrimSpace(creds.Username))
	if creds.Username == "" || creds.Password == "" || utf8.RuneCountInString(creds.Username) > 32 {
		writeError(w, http.StatusBadRequest, "username and password are required")
		return credentials{}, false
	}
	if registering && utf8.RuneCountInString(creds.Password) < minPasswordLen {
		writeError(w, http.StatusBadRequest, "password must be at least 8 characters")
		return credentials{}, false
	}
	return creds, true
}

func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, errorResponse{Error: message})
}

func withSecurityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		next.ServeHTTP(w, r)
	})
}
