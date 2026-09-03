package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const (
	version      = "2.4.1-btun-compat-keepalive"
	modeProbe    = 0
	modeUpload   = 1
	modeDownload = 2
	modeBatch    = 3
	modeAck      = 4
	statusOK     = 0
	statusError  = 1
	statusData   = 2
	maxBody      = 2 * 1024 * 1024
	minProbe     = 10
)

type config struct {
	listen             string
	port               int
	backendHost        string
	backendPort        int
	sessionTTL         time.Duration
	maxSessions        int
	requestTimeout     time.Duration
	readWait           time.Duration
	sequenceWait       time.Duration
	maxRequestsPerConn int
}

type request struct {
	mode byte
	sid  [16]byte
	seq  uint64
	body []byte
}

type batchCache struct {
	count   int
	chunks  [][]byte
	created time.Time
}

type session struct {
	sid      [16]byte
	backend  net.Conn
	created  time.Time
	lastSeen atomic.Int64
	closed   atomic.Bool

	uploadMu      sync.Mutex
	nextUpload    uint64
	uploadPending map[uint64][]byte

	downMu       sync.Mutex
	nextDownload uint64
	batchCache   map[uint64]batchCache

	pumpMu     sync.Mutex
	pumpBuf    bytes.Buffer
	pumpErr    error
	pumpSignal chan struct{}
	pumpSpace  chan struct{}
}

type server struct {
	cfg        config
	sessionsMu sync.RWMutex
	sessions   map[[16]byte]*session
	listener   net.Listener
	stop       chan struct{}
}

func main() {
	var cfg config
	var ttlSec int
	var reqTimeoutSec int
	var readWaitMS int
	var seqWaitSec int
	var showVersion bool
	var selfTest bool
	flag.StringVar(&cfg.listen, "listen", "0.0.0.0", "listen address")
	flag.IntVar(&cfg.port, "port", 80, "BHTTP TCP port")
	flag.StringVar(&cfg.backendHost, "backend-host", "127.0.0.1", "SSH backend host")
	flag.IntVar(&cfg.backendPort, "backend-port", 22, "SSH backend port")
	flag.IntVar(&ttlSec, "session-ttl", 180, "session TTL seconds")
	flag.IntVar(&cfg.maxSessions, "max-sessions", 1024, "max concurrent sessions")
	flag.IntVar(&reqTimeoutSec, "request-timeout", 30, "physical request connection timeout seconds")
	flag.IntVar(&readWaitMS, "read-wait-ms", 2, "maximum wait for pumped downstream data per requested batch in ms")
	flag.IntVar(&seqWaitSec, "sequence-wait", 6, "out-of-order batch sequence wait seconds")
	flag.IntVar(&cfg.maxRequestsPerConn, "max-requests-per-conn", 2048, "requests per physical TCP connection")
	flag.BoolVar(&showVersion, "version", false, "print version")
	flag.BoolVar(&showVersion, "v", false, "print version")
	flag.BoolVar(&selfTest, "self-test", false, "run protocol self-test")
	flag.Parse()
	if showVersion {
		fmt.Printf("SuperFlash BHTTP Server %s\n", version)
		return
	}
	if selfTest {
		if err := runSelfTest(); err != nil {
			fmt.Fprintln(os.Stderr, "BHTTP_SELF_TEST_FAIL:", err)
			os.Exit(1)
		}
		fmt.Printf("BHTTP_SELF_TEST_PASS version=%s framing=29 response=5 crypt=SHA256-XOR BHP1=ORIGINAL uploadProbe=request-param downloadProbe=response-param\n", version)
		return
	}
	if cfg.port < 1 || cfg.port > 65535 || cfg.backendPort < 1 || cfg.backendPort > 65535 {
		log.Fatal("invalid port")
	}
	if cfg.maxSessions < 1 {
		cfg.maxSessions = 1
	}
	if cfg.maxRequestsPerConn < 1 {
		cfg.maxRequestsPerConn = 1
	}
	cfg.sessionTTL = time.Duration(ttlSec) * time.Second
	cfg.requestTimeout = time.Duration(reqTimeoutSec) * time.Second
	cfg.readWait = time.Duration(readWaitMS) * time.Millisecond
	cfg.sequenceWait = time.Duration(seqWaitSec) * time.Second

	s := &server{cfg: cfg, sessions: make(map[[16]byte]*session), stop: make(chan struct{})}
	if err := s.serve(); err != nil && !errors.Is(err, net.ErrClosed) {
		log.Fatal(err)
	}
}

func (s *server) serve() error {
	addr := net.JoinHostPort(s.cfg.listen, strconv.Itoa(s.cfg.port))
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	s.listener = ln
	log.Printf("SuperFlash BHTTP %s listening on %s -> SSH %s:%d", version, addr, s.cfg.backendHost, s.cfg.backendPort)
	go s.cleanupLoop()
	sig := make(chan os.Signal, 2)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	go func() { <-sig; close(s.stop); _ = ln.Close(); s.closeAll() }()
	for {
		c, err := ln.Accept()
		if err != nil {
			return err
		}
		if tc, ok := c.(*net.TCPConn); ok {
			_ = tc.SetNoDelay(true)
			_ = tc.SetKeepAlive(true)
			_ = tc.SetKeepAlivePeriod(30 * time.Second)
		}
		go s.handleConn(c)
	}
}

func (s *server) handleConn(c net.Conn) {
	defer c.Close()
	br := bufio.NewReaderSize(c, 64*1024)
	bw := bufio.NewWriterSize(c, 64*1024)
	for i := 0; i < s.cfg.maxRequestsPerConn; i++ {
		_ = c.SetReadDeadline(time.Now().Add(s.cfg.requestTimeout))
		req, err := readRequest(br)
		if err != nil {
			if !errors.Is(err, io.EOF) && !isTimeout(err) {
				log.Printf("request read failed from %s: %v", c.RemoteAddr(), err)
			}
			return
		}
		_ = c.SetWriteDeadline(time.Now().Add(s.cfg.requestTimeout))
		keep, err := s.processRequest(req, bw)
		if err != nil {
			_ = writeResponse(bw, statusError, []byte(shortErr(err)))
			_ = bw.Flush()
			return
		}
		if err := bw.Flush(); err != nil {
			return
		}
		if !keep {
			return
		}
	}
}

func (s *server) processRequest(req request, w *bufio.Writer) (bool, error) {
	switch req.mode {
	case modeProbe:
		body, err := handleProbe(req.sid, req.body)
		if err != nil {
			return false, err
		}
		return false, writeResponse(w, statusOK, body)
	case modeUpload:
		if len(req.body) == 0 {
			if err := s.register(req.sid); err != nil {
				return false, err
			}
			return false, writeResponse(w, statusOK, nil)
		}
		sess := s.get(req.sid)
		if sess == nil {
			return false, errors.New("unknown session")
		}
		sess.touch()
		clear := crypt(req.body, req.sid, modeUpload, req.seq, false)
		if err := sess.upload(req.seq, clear); err != nil {
			return false, err
		}
		return true, writeResponse(w, statusOK, nil)
	case modeBatch:
		sess := s.get(req.sid)
		if sess == nil {
			return false, errors.New("unknown session")
		}
		sess.touch()
		clear := crypt(req.body, req.sid, modeBatch, req.seq, false)
		if len(clear) != 6 {
			return false, fmt.Errorf("invalid batch request length %d", len(clear))
		}
		chunkSize := int(binary.BigEndian.Uint32(clear[0:4]))
		count := int(clear[5])
		if chunkSize < 1 || chunkSize > 65536 || count < 1 || count > 64 {
			return false, errors.New("invalid batch parameters")
		}
		chunks, err := sess.downloadBatch(req.seq, chunkSize, count, s.cfg.readWait, s.cfg.sequenceWait)
		if err != nil {
			return false, err
		}
		for i, ch := range chunks {
			enc := crypt(ch, req.sid, modeBatch, req.seq+uint64(i), true)
			body := make([]byte, 4+len(enc))
			binary.BigEndian.PutUint32(body[:4], uint32(len(enc)))
			copy(body[4:], enc)
			if err := writeResponse(w, statusData, body); err != nil {
				return false, err
			}
		}
		return true, nil
	case modeAck:
		sess := s.get(req.sid)
		if sess == nil {
			return false, errors.New("unknown session")
		}
		sess.touch()
		sess.ack(req.seq)
		return true, writeResponse(w, statusOK, nil)
	default:
		return false, fmt.Errorf("unsupported mode %d", req.mode)
	}
}

func readRequest(r *bufio.Reader) (request, error) {
	var req request
	hdr := make([]byte, 29)
	if _, err := io.ReadFull(r, hdr); err != nil {
		return req, err
	}
	req.mode = hdr[0]
	copy(req.sid[:], hdr[1:17])
	req.seq = binary.BigEndian.Uint64(hdr[17:25])
	n := int(binary.BigEndian.Uint32(hdr[25:29]))
	if n < 0 || n > maxBody {
		return req, fmt.Errorf("request too large: %d", n)
	}
	req.body = make([]byte, n)
	if _, err := io.ReadFull(r, req.body); err != nil {
		return req, err
	}
	return req, nil
}

func writeResponse(w io.Writer, status byte, body []byte) error {
	if len(body) > maxBody {
		return fmt.Errorf("response too large: %d", len(body))
	}
	hdr := []byte{status, 0, 0, 0, 0}
	binary.BigEndian.PutUint32(hdr[1:], uint32(len(body)))
	if _, err := w.Write(hdr); err != nil {
		return err
	}
	if len(body) > 0 {
		_, err := w.Write(body)
		return err
	}
	return nil
}

func handleProbe(sid [16]byte, encrypted []byte) ([]byte, error) {
	clear := crypt(encrypted, sid, modeProbe, 0, false)
	if len(clear) < minProbe {
		return nil, errors.New("invalid BHP1 probe")
	}
	if string(clear[:4]) != "BHP1" || clear[4] != 1 {
		return nil, errors.New("invalid BHP1 probe")
	}
	inner := int(clear[5])
	param := int(binary.BigEndian.Uint32(clear[6:10]))
	if inner < modeProbe || inner > modeAck || param < 0 || param > maxBody {
		return nil, errors.New("invalid BHP1 probe")
	}
	expectedReq := minProbe
	if inner == modeUpload && param > expectedReq {
		expectedReq = param
	}
	if len(clear) != expectedReq {
		return nil, fmt.Errorf("invalid BHP1 request mode=%d length=%d expected=%d", inner, len(clear), expectedReq)
	}
	if err := validatePattern(clear); err != nil {
		return nil, err
	}
	responseLen := minProbe
	if inner == modeDownload && param > responseLen {
		responseLen = param
	}
	resp := make([]byte, responseLen)
	copy(resp[:4], []byte("BHP1"))
	resp[4] = 1
	resp[5] = byte(inner)
	binary.BigEndian.PutUint32(resp[6:10], uint32(param))
	fillPattern(resp)
	return crypt(resp, sid, modeProbe, 0, true), nil
}

func validatePattern(b []byte) error {
	for i := 10; i < len(b); i++ {
		if b[i] != byte((i*31)&0xff) {
			return fmt.Errorf("BHP1 corrupt byte %d", i)
		}
	}
	return nil
}
func fillPattern(b []byte) {
	for i := 10; i < len(b); i++ {
		b[i] = byte((i * 31) & 0xff)
	}
}

func crypt(input []byte, sid [16]byte, mode byte, seq uint64, response bool) []byte {
	out := make([]byte, len(input))
	state := make([]byte, 30)
	copy(state[:16], sid[:])
	state[16] = mode
	binary.BigEndian.PutUint64(state[17:25], seq)
	if response {
		state[25] = 1
	}
	off := 0
	block := uint32(0)
	for off < len(input) {
		binary.BigEndian.PutUint32(state[26:30], block)
		sum := sha256.Sum256(state)
		n := len(input) - off
		if n > 32 {
			n = 32
		}
		for i := 0; i < n; i++ {
			out[off+i] = input[off+i] ^ sum[i]
		}
		off += n
		block++
	}
	return out
}

func (s *server) register(sid [16]byte) error {
	s.sessionsMu.Lock()
	if old := s.sessions[sid]; old != nil && !old.closed.Load() {
		old.touch()
		s.sessionsMu.Unlock()
		return nil
	}
	if len(s.sessions) >= s.cfg.maxSessions {
		s.sessionsMu.Unlock()
		return errors.New("too many sessions")
	}
	s.sessionsMu.Unlock()

	backend, err := net.DialTimeout("tcp", net.JoinHostPort(s.cfg.backendHost, strconv.Itoa(s.cfg.backendPort)), 8*time.Second)
	if err != nil {
		return fmt.Errorf("backend connect: %w", err)
	}
	if tc, ok := backend.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
		_ = tc.SetKeepAlive(true)
		_ = tc.SetKeepAlivePeriod(30 * time.Second)
	}
	sess := &session{sid: sid, backend: backend, created: time.Now(), uploadPending: make(map[uint64][]byte), batchCache: make(map[uint64]batchCache), pumpSignal: make(chan struct{}, 1), pumpSpace: make(chan struct{}, 1)}
	sess.touch()
	s.sessionsMu.Lock()
	if old := s.sessions[sid]; old != nil {
		old.close()
	}
	s.sessions[sid] = sess
	s.sessionsMu.Unlock()
	go sess.pumpBackend()
	return nil
}

func (s *server) get(sid [16]byte) *session {
	s.sessionsMu.RLock()
	v := s.sessions[sid]
	s.sessionsMu.RUnlock()
	return v
}
func (s *server) cleanupLoop() {
	t := time.NewTicker(15 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-s.stop:
			return
		case now := <-t.C:
			s.sessionsMu.Lock()
			for sid, sess := range s.sessions {
				last := time.Unix(0, sess.lastSeen.Load())
				if sess.closed.Load() || now.Sub(last) > s.cfg.sessionTTL {
					sess.close()
					delete(s.sessions, sid)
				}
			}
			s.sessionsMu.Unlock()
		}
	}
}
func (s *server) closeAll() {
	s.sessionsMu.Lock()
	for sid, sess := range s.sessions {
		sess.close()
		delete(s.sessions, sid)
	}
	s.sessionsMu.Unlock()
}
func (sess *session) touch() { sess.lastSeen.Store(time.Now().UnixNano()) }
func (sess *session) close() {
	if sess.closed.CompareAndSwap(false, true) {
		_ = sess.backend.Close()
		sess.signalPump()
		sess.signalSpace()
	}
}

func (sess *session) upload(seq uint64, data []byte) error {
	if sess.closed.Load() {
		return errors.New("session closed")
	}
	sess.uploadMu.Lock()
	defer sess.uploadMu.Unlock()
	if seq < sess.nextUpload {
		return nil
	}
	if seq > sess.nextUpload+4096 {
		return errors.New("upload sequence too far ahead")
	}
	if _, ok := sess.uploadPending[seq]; !ok {
		cp := append([]byte(nil), data...)
		sess.uploadPending[seq] = cp
	}
	for {
		b, ok := sess.uploadPending[sess.nextUpload]
		if !ok {
			break
		}
		if err := writeAll(sess.backend, b); err != nil {
			sess.close()
			return err
		}
		delete(sess.uploadPending, sess.nextUpload)
		sess.nextUpload++
	}
	return nil
}

func writeAll(w io.Writer, b []byte) error {
	for len(b) > 0 {
		n, err := w.Write(b)
		if err != nil {
			return err
		}
		if n <= 0 {
			return io.ErrUnexpectedEOF
		}
		b = b[n:]
	}
	return nil
}

func (sess *session) pumpBackend() {
	buf := make([]byte, 64*1024)
	for !sess.closed.Load() {
		n, err := sess.backend.Read(buf)
		if n > 0 {
			cp := append([]byte(nil), buf[:n]...)
			for !sess.closed.Load() {
				sess.pumpMu.Lock()
				if sess.pumpBuf.Len() < 8*1024*1024 {
					_, _ = sess.pumpBuf.Write(cp)
					sess.pumpMu.Unlock()
					sess.signalPump()
					break
				}
				sess.pumpMu.Unlock()
				select {
				case <-sess.pumpSpace:
				case <-time.After(50 * time.Millisecond):
				}
			}
		}
		if err != nil {
			sess.pumpMu.Lock()
			sess.pumpErr = err
			sess.pumpMu.Unlock()
			sess.signalPump()
			return
		}
	}
}
func (sess *session) signalPump() {
	select {
	case sess.pumpSignal <- struct{}{}:
	default:
	}
}
func (sess *session) signalSpace() {
	select {
	case sess.pumpSpace <- struct{}{}:
	default:
	}
}
func (sess *session) takeChunk(max int, wait time.Duration) ([]byte, error) {
	deadline := time.Now().Add(wait)
	for {
		sess.pumpMu.Lock()
		if sess.pumpBuf.Len() > 0 {
			n := max
			if n > sess.pumpBuf.Len() {
				n = sess.pumpBuf.Len()
			}
			out := make([]byte, n)
			_, _ = io.ReadFull(&sess.pumpBuf, out)
			sess.pumpMu.Unlock()
			sess.signalSpace()
			return out, nil
		}
		err := sess.pumpErr
		sess.pumpMu.Unlock()
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil, nil
			}
			return nil, err
		}
		rem := time.Until(deadline)
		if rem <= 0 {
			return nil, nil
		}
		select {
		case <-sess.pumpSignal:
		case <-time.After(rem):
			return nil, nil
		}
	}
}

func cloneChunks(in [][]byte) [][]byte {
	out := make([][]byte, len(in))
	for i := range in {
		out[i] = append([]byte(nil), in[i]...)
	}
	return out
}
func (sess *session) downloadBatch(seq uint64, chunkSize, count int, readWait, sequenceWait time.Duration) ([][]byte, error) {
	deadline := time.Now().Add(sequenceWait)
	for {
		sess.downMu.Lock()
		if cached, ok := sess.batchCache[seq]; ok && cached.count == count {
			chunks := cloneChunks(cached.chunks)
			sess.downMu.Unlock()
			return chunks, nil
		}
		if seq < sess.nextDownload {
			sess.downMu.Unlock()
			return nil, errors.New("expired download retry")
		}
		if seq == sess.nextDownload {
			chunks := make([][]byte, count)
			for i := 0; i < count; i++ {
				ch, err := sess.takeChunk(chunkSize, readWait)
				if err != nil {
					sess.downMu.Unlock()
					sess.close()
					return nil, err
				}
				chunks[i] = ch
			}
			sess.batchCache[seq] = batchCache{count: count, chunks: cloneChunks(chunks), created: time.Now()}
			sess.nextDownload += uint64(count)
			// bound cache even if ACK is delayed
			if len(sess.batchCache) > 128 {
				cut := uint64(0)
				if sess.nextDownload > 1024 {
					cut = sess.nextDownload - 1024
				}
				for k := range sess.batchCache {
					if k < cut {
						delete(sess.batchCache, k)
					}
				}
			}
			sess.downMu.Unlock()
			return chunks, nil
		}
		sess.downMu.Unlock()
		if time.Now().After(deadline) {
			return nil, fmt.Errorf("out-of-order batch seq=%d next=%d", seq, sess.nextDownload)
		}
		time.Sleep(2 * time.Millisecond)
	}
}
func (sess *session) ack(seq uint64) {
	sess.downMu.Lock()
	for start, b := range sess.batchCache {
		end := start + uint64(b.count) - 1
		if end <= seq {
			delete(sess.batchCache, start)
		}
	}
	sess.downMu.Unlock()
}

func runSelfTest() error {
	var sid [16]byte
	for i := range sid {
		sid[i] = byte(i + 1)
	}
	// crypt round trip, response bit intentionally symmetric only with same direction flag
	p := []byte("hello-bhttp")
	e := crypt(p, sid, modeUpload, 7, false)
	d := crypt(e, sid, modeUpload, 7, false)
	if !bytes.Equal(p, d) {
		return errors.New("crypt roundtrip failed")
	}
	// Original BHP1: upload request is param bytes, upload response 10. Download request 10, response param.
	for _, tc := range []struct{ mode, param, reqLen, respLen int }{{0, 0, 10, 10}, {1, 32768, 32768, 10}, {2, 195, 10, 195}, {2, 147, 10, 147}, {3, 8, 10, 10}, {4, 1, 10, 10}} {
		req := make([]byte, tc.reqLen)
		copy(req[:4], []byte("BHP1"))
		req[4] = 1
		req[5] = byte(tc.mode)
		binary.BigEndian.PutUint32(req[6:10], uint32(tc.param))
		fillPattern(req)
		enc := crypt(req, sid, modeProbe, 0, false)
		resp, err := handleProbe(sid, enc)
		if err != nil {
			return err
		}
		clear := crypt(resp, sid, modeProbe, 0, true)
		if len(clear) != tc.respLen {
			return fmt.Errorf("probe mode %d len %d expected %d", tc.mode, len(clear), tc.respLen)
		}
		if err := validatePattern(clear); err != nil {
			return err
		}
	}
	return nil
}
func isTimeout(err error) bool { var ne net.Error; return errors.As(err, &ne) && ne.Timeout() }
func shortErr(err error) string {
	if err == nil {
		return ""
	}
	s := err.Error()
	s = strings.ReplaceAll(s, "\n", " ")
	if len(s) > 200 {
		s = s[:200]
	}
	return s
}

func init() { log.SetFlags(log.Ldate | log.Ltime | log.Lmicroseconds); _ = runtime.GOMAXPROCS(0) }
