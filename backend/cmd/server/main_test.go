package main

import (
	"net/http"
	"net/http/httptest"
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

func TestMissingBearerTokenIsRejected(t *testing.T) {
	s := &server{jwtSecret: []byte("01234567890123456789012345678901")}
	if _, err := s.parseBearerToken(httptest.NewRequest(http.MethodGet, "/api/v1/auth/me", nil)); err == nil {
		t.Fatal("parseBearerToken() accepted a request without credentials")
	}
}
