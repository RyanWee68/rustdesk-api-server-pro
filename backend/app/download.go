package app

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"strings"

	"rustdesk-api-server-pro/internal/errcode"

	"github.com/kataras/iris/v12"
)

type publicDownload struct {
	fileName string
	sha256   string
}

var publicDownloads = map[string]publicDownload{
	"/downloads/rustdesk.jtzxsoft.com.cert.cer": {
		fileName: "rustdesk.jtzxsoft.com.cert.cer",
		sha256:   "F56A892AB90B0E85687403979D5F9901084B6E2657C74EFF6DC9E93AEDE0D96D",
	},
	"/downloads/rustdesk-1.4.9-x86_64.exe": {
		fileName: "rustdesk-1.4.9-x86_64.exe",
		sha256:   "EAEDEB0088E687BF46F7C46A9C6EA5493CE51F3134DFD6ACBEDB47B5B9136274",
	},
}

// SetDownloadRoutes 注册管理端固定文件下载地址，不允许客户端传入文件路径。
func SetDownloadRoutes(app *iris.Application, downloadDir string) {
	setDownloadRoutes(app, downloadDir, publicDownloads)
}

func setDownloadRoutes(app *iris.Application, downloadDir string, downloads map[string]publicDownload) {
	for routePath, download := range downloads {
		path := filepath.Join(downloadDir, download.fileName)
		app.Get(routePath, func(ctx iris.Context) {
			info, err := os.Lstat(path)
			if err != nil || !info.Mode().IsRegular() {
				ctx.StopWithJSON(iris.StatusNotFound, iris.Map{
					"code":    errcode.ERRB007.Code,
					"data":    nil,
					"message": errcode.New(errcode.ERRB007.Code, errcode.ERRB007.Message).Error(),
				})
				return
			}
			if download.sha256 != "" {
				matches, err := fileMatchesSHA256(path, download.sha256)
				if err != nil || !matches {
					ctx.Application().Logger().Errorf("%s: %s", errcode.ERRB009.Code, download.fileName)
					ctx.StopWithJSON(iris.StatusInternalServerError, iris.Map{
						"code":    errcode.ERRB009.Code,
						"data":    nil,
						"message": errcode.New(errcode.ERRB009.Code, errcode.ERRB009.Message).Error(),
					})
					return
				}
			}

			ctx.Header("X-Content-Type-Options", "nosniff")
			if err := ctx.SendFile(path, download.fileName); err != nil {
				ctx.Application().Logger().Errorf("%s: %v", errcode.ERRB008.Code, err)
				if ctx.ResponseWriter().Written() <= 0 {
					ctx.StopWithJSON(iris.StatusInternalServerError, iris.Map{
						"code":    errcode.ERRB008.Code,
						"data":    nil,
						"message": errcode.New(errcode.ERRB008.Code, errcode.ERRB008.Message).Error(),
					})
				}
			}
		})
	}
}

func fileMatchesSHA256(path, expected string) (bool, error) {
	file, err := os.Open(path)
	if err != nil {
		return false, err
	}
	defer file.Close()

	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return false, err
	}
	return strings.EqualFold(hex.EncodeToString(hash.Sum(nil)), expected), nil
}
