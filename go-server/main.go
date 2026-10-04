package main

import (
	"context"
	"encoding/json"
	"log"
	"math/rand/v2"
	"net/http"
	"os"
	"strconv"

	gojson "github.com/goccy/go-json"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const pageQuery = `SELECT id, name, email, active, tags FROM users WHERE id > $1 ORDER BY id LIMIT 50`

// writeJSON sends the body with a Content-Length (no chunked encoding), like axum's Json does.
func writeJSON(w http.ResponseWriter, body []byte, err error) {
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.Write(body)
}

// staticTags is shared by every in-memory user, so that handler allocates no per-user slices (like Rust's &'static).
var staticTags = []string{"a", "b"}

type User struct {
	ID     int32    `json:"id"`
	Name   string   `json:"name"`
	Email  string   `json:"email"`
	Active bool     `json:"active"`
	Tags   []string `json:"tags"`
}

func users(w http.ResponseWriter, r *http.Request) {
	list := make([]User, 50)
	for i := range list {
		list[i] = User{
			ID:     int32(i),
			Name:   "User",
			Email:  "user@example.com",
			Active: i%2 == 0,
			Tags:   staticTags,
		}
	}
	body, err := json.Marshal(list)
	writeJSON(w, body, err)
}

func usersDB(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rows, err := pool.Query(
			r.Context(), pageQuery, rand.IntN(9950),
		)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		list, err := pgx.CollectRows(rows, pgx.RowToStructByPos[User])
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		body, err := json.Marshal(list)
		writeJSON(w, body, err)
	}
}

// usersScan is Go's tuned path: hand-written row scanning (no reflection) and the faster go-json encoder.
func usersScan(pool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		rows, err := pool.Query(
			r.Context(), pageQuery, rand.IntN(9950),
		)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		defer rows.Close()
		list := make([]User, 0, 50)
		for rows.Next() {
			var u User
			if err := rows.Scan(
				&u.ID, &u.Name, &u.Email, &u.Active, &u.Tags,
			); err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			list = append(list, u)
		}
		if err := rows.Err(); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		body, err := gojson.Marshal(list)
		writeJSON(w, body, err)
	}
}

func main() {
	pool, err := pgxpool.New(context.Background(), os.Getenv("DATABASE_URL")+"?pool_max_conns=20&pool_min_conns=20")
	if err != nil {
		log.Fatal(err)
	}
	http.HandleFunc("/users", users)
	http.HandleFunc("/users-db", usersDB(pool))
	http.HandleFunc("/users-scan", usersScan(pool))
	log.Fatal(http.ListenAndServe("127.0.0.1:8081", nil))
}
