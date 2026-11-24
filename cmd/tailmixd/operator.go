package main

import (
	"context"
	"fmt"
	"os/user"
	"strconv"

	"github.com/maisem/tailmix/controlapi"
)

// operatorUID returns the configured operator's numeric user ID, or "" when
// none is configured. It does not take s.mu so that request authorization
// never waits behind a slow mutation.
func (s *supervisor) operatorUID() string {
	uid, _ := s.operator.Load().(string)
	return uid
}

func (s *supervisor) Operator(context.Context) (controlapi.Operator, error) {
	return operatorView(s.operatorUID()), nil
}

func (s *supervisor) SetOperator(_ context.Context, request controlapi.SetOperatorRequest) (controlapi.Operator, error) {
	uid, err := parseOperatorUID(request.UID)
	if err != nil {
		return controlapi.Operator{}, err
	}
	return s.saveOperator(uid)
}

func (s *supervisor) ClearOperator(context.Context) (controlapi.Operator, error) {
	return s.saveOperator("")
}

func (s *supervisor) saveOperator(uid string) (controlapi.Operator, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.st.OperatorUID != uid {
		before := s.st.OperatorUID
		s.st.OperatorUID = uid
		if err := s.store.Save(s.st); err != nil {
			s.st.OperatorUID = before
			return controlapi.Operator{}, fmt.Errorf("save operator: %w", err)
		}
	}
	s.operator.Store(uid)
	return operatorView(uid), nil
}

// parseOperatorUID accepts a canonical, non-root numeric user ID.
func parseOperatorUID(value string) (string, error) {
	n, err := strconv.ParseUint(value, 10, 32)
	if err != nil || strconv.FormatUint(n, 10) != value {
		return "", controlapi.NewError("invalid_request", "operator must be a numeric user ID")
	}
	if n == 0 {
		return "", controlapi.NewError("invalid_request", "root is always allowed and cannot be the operator")
	}
	return value, nil
}

func operatorView(uid string) controlapi.Operator {
	if uid == "" {
		return controlapi.Operator{}
	}
	result := controlapi.Operator{UID: uid}
	if u, err := user.LookupId(uid); err == nil {
		result.Username = u.Username
	}
	return result
}
