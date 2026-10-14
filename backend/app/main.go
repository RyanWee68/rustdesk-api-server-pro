package app

import (
	"context"
	"crypto/tls"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"rustdesk-api-server-pro/app/middleware"
	"rustdesk-api-server-pro/config"
	"rustdesk-api-server-pro/db"
	"rustdesk-api-server-pro/internal/errcode"
	"rustdesk-api-server-pro/util"

	"github.com/kataras/iris/v12"
	"xorm.io/xorm"
)

func newBaseApp(cfg *config.ServerConfig, dbEngine *xorm.Engine) (*iris.Application, error) {
	app := iris.Default()
	if dbEngine == nil {
		return nil, errcode.New(errcode.ERRB001.Code, errcode.ERRB001.Message)
	}
	app.RegisterDependency(dbEngine, cfg)

	app.OnErrorCode(iris.StatusNotFound, func(context iris.Context) {
		context.Application().Logger().Infof("(404)▶ %s:%s", context.Method(), context.Request().URL.Path)
	})

	app.Use(iris.Compression)
	app.Use(middleware.ContainerLogRecorder(app))
	if cfg.HttpConfig.PrintRequestLog {
		app.Use(middleware.RequestLogger(cfg.DebugMode))
	}

	return app, nil
}

func newApp(cfg *config.ServerConfig, dbEngine *xorm.Engine) (*iris.Application, error) {
	app, err := newBaseApp(cfg, dbEngine)
	if err != nil {
		return nil, err
	}
	SetRoute(app)
	app.HandleDir("/", iris.Dir(cfg.HttpConfig.StaticDir))

	return app, nil
}

func newClientApp(cfg *config.ServerConfig, dbEngine *xorm.Engine) (*iris.Application, error) {
	app, err := newBaseApp(cfg, dbEngine)
	if err != nil {
		return nil, err
	}
	SetClientRoute(app)
	SetInternalRoute(app)
	return app, nil
}

func newAdminApp(cfg *config.ServerConfig, dbEngine *xorm.Engine) (*iris.Application, error) {
	app, err := newBaseApp(cfg, dbEngine)
	if err != nil {
		return nil, err
	}
	SetAdminRoute(app)
	app.HandleDir("/", iris.Dir(cfg.HttpConfig.StaticDir))
	return app, nil
}

func StartServer() (bool, error) {
	return StartServerWithContext(context.Background())
}

func StartServerWithContext(ctx context.Context) (bool, error) {
	cfg := config.GetServerConfig()
	if config.IsUnsafeSignKey(cfg.SignKey) {
		return false, errcode.New(errcode.ERRB002.Code, errcode.ERRB002.Message)
	}

	dbEngine, err := db.NewEngine(cfg.Db)
	if err != nil {
		return false, err
	}

	clientPort := strings.TrimSpace(cfg.HttpConfig.Port)
	adminPort := strings.TrimSpace(cfg.HttpConfig.AdminPort)
	if adminPort == "" {
		adminPort = clientPort
	}

	var clientApp *iris.Application
	var adminApp *iris.Application
	if adminPort == clientPort {
		clientApp, err = newApp(cfg, dbEngine)
	} else {
		clientApp, err = newClientApp(cfg, dbEngine)
		if err == nil {
			adminApp, err = newAdminApp(cfg, dbEngine)
		}
	}
	if err != nil {
		return false, err
	}

	if err := StartJobs(cfg, dbEngine); err != nil {
		return false, err
	}

	if adminPort == clientPort {
		middleware.RecordContainerEvent(dbEngine, "INFO", "system", "Server started on port "+clientPort)
	} else {
		middleware.RecordContainerEvent(dbEngine, "INFO", "system", "客户端 API 监听端口 "+clientPort+"，管理后台监听端口 "+adminPort)
	}

	if cfg.HttpConfig.TLSPort != "" {
		tlsTargetPort := clientPort
		if adminPort != "" {
			tlsTargetPort = adminPort
		}
		go startTLSServer(clientApp, cfg, tlsTargetPort)
	}

	go func() {
		defer func() {
			if r := recover(); r != nil {
				_ = r
			}
		}()
		<-ctx.Done()
		_ = clientApp.Shutdown(ctx)
		if adminApp != nil {
			_ = adminApp.Shutdown(ctx)
		}
	}()

	if adminApp != nil {
		adminErrCh := make(chan error, 1)
		go func() {
			if listenErr := adminApp.Listen(adminPort, iris.WithoutBodyConsumptionOnUnmarshal); listenErr != nil && ctx.Err() == nil {
				adminErrCh <- listenErr
			}
		}()
		select {
		case listenErr := <-adminErrCh:
			return false, listenErr
		case <-time.After(200 * time.Millisecond):
		case <-ctx.Done():
			return true, nil
		}
	}

	err = clientApp.Listen(clientPort, iris.WithoutBodyConsumptionOnUnmarshal)
	if err != nil && ctx.Err() != nil {
		return true, nil
	}
	if err != nil {
		if adminApp != nil {
			shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			_ = adminApp.Shutdown(shutdownCtx)
			cancel()
		}
		return false, err
	}

	return true, nil
}

// startTLSServer 在 goroutine 中启动 HTTPS 反向代理服务器，用于 WebAuthn 等需要安全上下文的功能
func startTLSServer(app *iris.Application, cfg *config.ServerConfig, targetPort string) {
	certFile := cfg.HttpConfig.TLSCertFile
	keyFile := cfg.HttpConfig.TLSKeyFile

	if certFile == "" || keyFile == "" {
		certFile = filepath.Join(filepath.Dir(cfg.Db.Dsn), "tls-cert.pem")
		keyFile = filepath.Join(filepath.Dir(cfg.Db.Dsn), "tls-key.pem")
	}

	if _, err := os.Stat(certFile); os.IsNotExist(err) {
		hosts := cfg.HttpConfig.TLSHosts
		if len(hosts) == 0 {
			hosts = []string{"localhost", "127.0.0.1"}
		}
		app.Logger().Infof("生成自签名证书: hosts=%v", hosts)
		if _, _, err := util.GenerateSelfSignedCert(certFile, keyFile, hosts); err != nil {
			app.Logger().Errorf("生成自签名证书失败: %v", err)
			return
		}
	}

	httpPort := strings.TrimPrefix(targetPort, ":")
	if httpPort == "" {
		httpPort = "8080"
	}
	target := &url.URL{Scheme: "http", Host: "127.0.0.1:" + httpPort}
	proxy := httputil.NewSingleHostReverseProxy(target)
	originalDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		originalDirector(req)
		req.Header.Set("X-Forwarded-Proto", "https")
	}

	tlsServer := &http.Server{
		Addr:    cfg.HttpConfig.TLSPort,
		Handler: proxy,
		TLSConfig: &tls.Config{
			MinVersion: tls.VersionTLS12,
		},
		ReadHeaderTimeout: 10 * time.Second,
	}

	app.Logger().Infof("HTTPS 反向代理监听: %s -> http://127.0.0.1:%s", cfg.HttpConfig.TLSPort, httpPort)
	if err := tlsServer.ListenAndServeTLS(certFile, keyFile); err != nil && err != http.ErrServerClosed {
		app.Logger().Errorf("HTTPS 服务器启动失败: %v", err)
	}
}
