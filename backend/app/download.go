package app

import (
	"os"
	"path/filepath"

	"rustdesk-api-server-pro/internal/errcode"

	"github.com/kataras/iris/v12"
)

var publicDownloads = map[string]string{
	"/downloads/rustdesk.jtzxsoft.com.cert.cer": "rustdesk.jtzxsoft.com.cert.cer",
	"/downloads/rustdesk-1.4.9-x86_64.exe":      "rustdesk-1.4.9-x86_64.exe",
}

// SetDownloadRoutes 注册管理端固定文件下载地址，不允许客户端传入文件路径。
func SetDownloadRoutes(app *iris.Application, downloadDir string) {
	for routePath, fileName := range publicDownloads {
		path := filepath.Join(downloadDir, fileName)
		app.Get(routePath, func(ctx iris.Context) {
			info, err := os.Stat(path)
			if err != nil || !info.Mode().IsRegular() {
				ctx.StopWithJSON(iris.StatusNotFound, iris.Map{
					"code":    errcode.ERRB007.Code,
					"data":    nil,
					"message": errcode.New(errcode.ERRB007.Code, errcode.ERRB007.Message).Error(),
				})
				return
			}

			ctx.Header("X-Content-Type-Options", "nosniff")
			if err := ctx.SendFile(path, fileName); err != nil {
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
