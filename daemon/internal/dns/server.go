package dns

import (
	"context"
	"encoding/binary"
	"errors"
	"net"
	"strings"
	"sync"
)

type Server struct {
	addr string
	conn net.PacketConn
	mu   sync.Mutex
}

func NewServer(addr string) *Server {
	return &Server{addr: addr}
}

func (s *Server) Start(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.conn != nil {
		return nil
	}

	conn, err := net.ListenPacket("udp", s.addr)
	if err != nil {
		return err
	}
	s.conn = conn

	go func() {
		<-ctx.Done()
		_ = s.Close()
	}()

	go s.serve()
	return nil
}

func (s *Server) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.conn == nil {
		return nil
	}
	err := s.conn.Close()
	s.conn = nil
	return err
}

func (s *Server) serve() {
	buffer := make([]byte, 512)
	for {
		n, address, err := s.conn.ReadFrom(buffer)
		if err != nil {
			return
		}

		response, buildErr := buildResponse(buffer[:n])
		if buildErr != nil {
			continue
		}
		_, _ = s.conn.WriteTo(response, address)
	}
}

func buildResponse(request []byte) ([]byte, error) {
	if len(request) < 12 {
		return nil, errors.New("dns request too short")
	}

	id := request[:2]
	question, name, qtype, qclass, err := parseQuestion(request)
	if err != nil {
		return nil, err
	}

	flags := uint16(0x8180)
	answerCount := uint16(0)
	responseCode := uint16(0)
	answer := []byte{}

	if qclass == 1 && strings.HasSuffix(name, ".test") {
		switch qtype {
		case 1:
			answerCount = 1
			answer = append(answer, []byte{0xc0, 0x0c}...)
			answer = append(answer, 0x00, 0x01, 0x00, 0x01)
			answer = append(answer, 0x00, 0x00, 0x00, 0x3c)
			answer = append(answer, 0x00, 0x04)
			answer = append(answer, []byte{127, 0, 0, 1}...)
		case 28:
			answerCount = 1
			answer = append(answer, []byte{0xc0, 0x0c}...)
			answer = append(answer, 0x00, 0x1c, 0x00, 0x01)
			answer = append(answer, 0x00, 0x00, 0x00, 0x3c)
			answer = append(answer, 0x00, 0x10)
			answer = append(answer, make([]byte, 15)...)
			answer = append(answer, 0x01)
		}
	} else {
		responseCode = 3
	}

	flags = (flags &^ 0x000f) | responseCode
	response := make([]byte, 12)
	copy(response[:2], id)
	binary.BigEndian.PutUint16(response[2:4], flags)
	binary.BigEndian.PutUint16(response[4:6], 1)
	binary.BigEndian.PutUint16(response[6:8], answerCount)
	binary.BigEndian.PutUint16(response[8:10], 0)
	binary.BigEndian.PutUint16(response[10:12], 0)
	response = append(response, question...)
	response = append(response, answer...)
	return response, nil
}

func parseQuestion(request []byte) ([]byte, string, uint16, uint16, error) {
	offset := 12
	labels := make([]string, 0, 4)
	for {
		if offset >= len(request) {
			return nil, "", 0, 0, errors.New("invalid qname")
		}
		length := int(request[offset])
		offset++
		if length == 0 {
			break
		}
		if offset+length > len(request) {
			return nil, "", 0, 0, errors.New("invalid qname length")
		}
		labels = append(labels, string(request[offset:offset+length]))
		offset += length
	}

	if offset+4 > len(request) {
		return nil, "", 0, 0, errors.New("question truncated")
	}
	question := request[12 : offset+4]
	qtype := binary.BigEndian.Uint16(request[offset : offset+2])
	qclass := binary.BigEndian.Uint16(request[offset+2 : offset+4])
	name := strings.ToLower(strings.Join(labels, "."))
	return question, name, qtype, qclass, nil
}
