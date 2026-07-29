package main

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSignedTokenAuthenticatesItsAccount(t *testing.T) {
	s := &server{jwtSecret: []byte("01234567890123456789012345678901")}
	token, err := s.signToken("account-id", "player")
	if err != nil {
		t.Fatalf("signToken() error = %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/v1/auth/me", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	claims, err := s.parseBearerToken(req)
	if err != nil {
		t.Fatalf("parseBearerToken() error = %v", err)
	}
	if claims.AccountID != "account-id" || claims.Username != "player" {
		t.Fatalf("claims = %#v", claims)
	}
}

func TestRoomCreatorTicketSQLGuardsAreAtomic(t *testing.T) {
	for name, predicate := range map[string]string{
		"bind only unbound unused unexpired ticket": "provision_instance_id IS NULL AND used_at IS NULL AND expires_at > NOW()",
		"redeem matching instance credential once before expiry": "provision_instance_id = $2 AND world_credential_hash = $3 AND used_at IS NULL AND expires_at > NOW()",
	} {
		t.Run(name, func(t *testing.T) {
			query := roomCreatorTicketBindSQL
			if strings.Contains(predicate, "world_credential_hash") { query = roomCreatorTicketRedeemSQL }
			if !strings.Contains(query, "UPDATE room_creator_tickets") || !strings.Contains(query, predicate) {
				t.Fatalf("atomic predicate missing from query: %s", predicate)
			}
		})
	}
	if !strings.Contains(roomCreatorTicketRedeemSQL, "RETURNING account_id") {
		t.Fatal("redeem must return the account from the same atomic update")
	}
}

func TestRoomCreatorTicketIsOpaqueAndTamperChangesLookupHash(t *testing.T) {
	ticket, ticketHash, _, err := newRoomCreatorTicket()
	if err != nil { t.Fatalf("newRoomCreatorTicket() error = %v", err) }
	if ticket == "" || ticketHash == "" { t.Fatal("ticket values must not be empty") }
	if ticket == ticketHash || len(ticket) < 32 { t.Fatalf("ticket is not an opaque random handle: %q", ticket) }
	if hashRoomCreatorTicket(ticket+"x") == ticketHash { t.Fatal("tampering must change the persisted lookup hash") }
	if containsAccountData(ticket, "account-id") { t.Fatalf("ticket leaked account data: %q", ticket) }
}

func containsAccountData(ticket, accountID string) bool { return len(accountID) > 0 && len(ticket) >= len(accountID) && stringContains(ticket, accountID) }
func stringContains(value, part string) bool { for i := 0; i+len(part) <= len(value); i++ { if value[i:i+len(part)] == part { return true } }; return false }

func TestRoomCreatorTicketValidationRejectsMissingInstanceBinding(t *testing.T) {
	s := &server{jwtSecret: []byte("01234567890123456789012345678901")}
	recorder := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/api/v1/rooms/creator-ticket/validate", nil)
	req.Header.Set("X-World-Server-Credential", "world-server-credential-with-32-bytes")
	s.validateRoomCreatorTicket(recorder, req)
	if recorder.Code != http.StatusBadRequest { t.Fatalf("status = %d", recorder.Code) }
}

func TestRoomCreatorTicketValidationRequiresInstanceBoundCredential(t *testing.T) {
	s := &server{}
	body := []byte(`{"ticket":"opaque","provision_instance_id":"00000000-0000-0000-0000-000000000001"}`)
	for name, credential := range map[string]string{"missing": "", "wrong-server": "short"} {
		t.Run(name, func(t *testing.T) {
			recorder := httptest.NewRecorder()
			req := httptest.NewRequest(http.MethodPost, "/api/v1/rooms/creator-ticket/validate", bytes.NewReader(body))
			if credential != "" { req.Header.Set("X-World-Server-Credential", credential) }
			s.validateRoomCreatorTicket(recorder, req)
			expected := http.StatusUnauthorized
			if recorder.Code != expected { t.Fatalf("status = %d", recorder.Code) }
		})
	}
}

func TestProvisionerCredentialAndInstanceBindingValidation(t *testing.T) {
	s := &server{provisionerCredential: []byte("provisioner-credential-with-32-bytes")}
	if !s.validProvisionerCredential("provisioner-credential-with-32-bytes") { t.Fatal("valid provisioner was rejected") }
	if s.validProvisionerCredential("wrong-provisioner-credential-value") { t.Fatal("wrong provisioner was accepted") }
	if validProvisionInstanceID("wrong-room") { t.Fatal("invalid instance binding was accepted") }
	if !validProvisionInstanceID("00000000-0000-0000-0000-000000000001") { t.Fatal("valid instance binding was rejected") }
}

func TestRoomCreatorTicketIssueRequiresAccessJWT(t *testing.T) {
	s := &server{jwtSecret: []byte("01234567890123456789012345678901")}
	recorder := httptest.NewRecorder()
	s.issueRoomCreatorTicket(recorder, httptest.NewRequest(http.MethodPost, "/api/v1/rooms/creator-ticket", nil))
	if recorder.Code != http.StatusUnauthorized { t.Fatalf("status = %d", recorder.Code) }
}

func TestMissingBearerTokenIsRejected(t *testing.T) {
	s := &server{jwtSecret: []byte("01234567890123456789012345678901")}
	if _, err := s.parseBearerToken(httptest.NewRequest(http.MethodGet, "/api/v1/auth/me", nil)); err == nil {
		t.Fatal("parseBearerToken() accepted a request without credentials")
	}
}
