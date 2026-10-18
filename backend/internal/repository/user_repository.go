package repository

import "rustdesk-api-server-pro/internal/core"

type UserRepository interface {
	List(query core.UserListQuery) (core.UserListResult, error)
	ExpireAuthTokenByRustdeskID(userID int, rustdeskID string) error
}
