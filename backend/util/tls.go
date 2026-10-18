package util

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"time"

	"rustdesk-api-server-pro/internal/errcode"
)

// GenerateSelfSignedCert 独占创建自签名 ECC 证书和私钥，不覆盖已有文件。
// hosts 参数指定证书覆盖的域名/IP列表，为空时使用 localhost
// 返回 certFile, keyFile, error
func GenerateSelfSignedCert(certFile, keyFile string, hosts []string) (string, string, error) {
	if len(hosts) == 0 {
		hosts = []string{"localhost", "127.0.0.1"}
	}

	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return "", "", errcode.New(errcode.ERRB011.Code, "无法生成 TLS 私钥")
	}

	serialNumberLimit := new(big.Int).Lsh(big.NewInt(1), 128)
	serialNumber, err := rand.Int(rand.Reader, serialNumberLimit)
	if err != nil {
		return "", "", errcode.New(errcode.ERRB011.Code, "无法生成 TLS 证书序列号")
	}

	dnsNames := make([]string, 0, len(hosts))
	ipAddrs := make([]net.IP, 0, len(hosts))
	for _, h := range hosts {
		if ip := net.ParseIP(h); ip != nil {
			ipAddrs = append(ipAddrs, ip)
		} else {
			dnsNames = append(dnsNames, h)
		}
	}
	if len(dnsNames) == 0 {
		dnsNames = []string{"localhost"}
	}

	template := x509.Certificate{
		SerialNumber: serialNumber,
		Subject: pkix.Name{
			Organization: []string{"RustDesk API Server Pro"},
			CommonName:   dnsNames[0],
		},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().AddDate(10, 0, 0),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              dnsNames,
		IPAddresses:           ipAddrs,
	}

	derBytes, err := x509.CreateCertificate(rand.Reader, &template, &template, &priv.PublicKey, priv)
	if err != nil {
		return "", "", errcode.New(errcode.ERRB011.Code, "无法签发 TLS 证书")
	}
	privBytes, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		return "", "", errcode.New(errcode.ERRB011.Code, "无法编码 TLS 私钥")
	}
	for _, file := range []string{certFile, keyFile} {
		if err := os.MkdirAll(filepath.Dir(file), 0755); err != nil {
			return "", "", errcode.New(errcode.ERRB011.Code, "无法创建 TLS 文件目录")
		}
	}
	if err := writeNewPEM(keyFile, &pem.Block{Type: "PRIVATE KEY", Bytes: privBytes}, 0600); err != nil {
		return "", "", errcode.New(errcode.ERRB011.Code, "无法独占创建 TLS 私钥，已有文件不会覆盖")
	}
	if err := writeNewPEM(certFile, &pem.Block{Type: "CERTIFICATE", Bytes: derBytes}, 0644); err != nil {
		_ = os.Remove(keyFile)
		return "", "", errcode.New(errcode.ERRB011.Code, "无法独占创建 TLS 证书，已有文件不会覆盖")
	}
	return certFile, keyFile, nil
}

// writeNewPEM 独占写入并检查关闭错误，只清理本次创建失败的文件。
func writeNewPEM(path string, block *pem.Block, mode os.FileMode) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return err
	}
	encodeErr := pem.Encode(file, block)
	closeErr := file.Close()
	if encodeErr != nil || closeErr != nil {
		_ = os.Remove(path)
		if encodeErr != nil {
			return encodeErr
		}
		return closeErr
	}
	return nil
}

// LoadOrCreateTLSCertificate 只在双文件均缺失时签发，并校验已有材料而不重签或修权限。
func LoadOrCreateTLSCertificate(certFile, keyFile string, hosts []string) (tls.Certificate, error) {
	failure := func(message string) (tls.Certificate, error) {
		return tls.Certificate{}, errcode.New(errcode.ERRB011.Code, message)
	}
	if certFile == "" || keyFile == "" || filepath.Clean(certFile) == filepath.Clean(keyFile) {
		return failure("TLS 证书与私钥必须指定不同的非空路径")
	}
	missing := 0
	for _, file := range []string{certFile, keyFile} {
		info, err := os.Lstat(file)
		if os.IsNotExist(err) {
			missing++
			continue
		}
		if err != nil || !info.Mode().IsRegular() {
			return failure("TLS 文件不存在、不可读或不是普通非链接文件")
		}
		if file == keyFile && runtime.GOOS != "windows" && info.Mode().Perm()&0077 != 0 {
			return failure("TLS 私钥不能允许组或其他用户访问")
		}
	}
	if missing == 1 {
		return failure("TLS 证书与私钥仅存在其中一个，拒绝自动补签或覆盖")
	}
	if missing == 2 {
		if _, _, err := GenerateSelfSignedCert(certFile, keyFile, hosts); err != nil {
			return tls.Certificate{}, err
		}
	}
	pair, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return failure("TLS 证书与私钥内容无效或不匹配")
	}
	leaf, err := x509.ParseCertificate(pair.Certificate[0])
	if err != nil {
		return failure("TLS 证书内容无效")
	}
	now := time.Now()
	if now.Before(leaf.NotBefore) || !now.Before(leaf.NotAfter) {
		return failure("TLS 证书尚未生效或已过期")
	}
	pair.Leaf = leaf
	return pair, nil
}
