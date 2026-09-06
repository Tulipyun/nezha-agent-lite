# 构建发行文件

运行两种目标的 ReleaseSmall 构建后：

    python scripts/package_release.py --version v0.1.0
    python scripts/check_publication.py

发行文件位于 release/：两个原始 ELF、各架构 tar.gz、SHA256SUMS 和 build-info.json。
版本标签表示本项目发布版本；兼容的上游协议版本仍为 v0.20.5。

将源码提交到 Git，二进制与校验文件上传到对应的 GitHub Release。
GitHub 自动提供标签对应的源码归档。release/、zig-out/、test-results/ 均不进入 Git。

打包器仅收集指定的二进制、README、安装说明及许可证，不收集真实设备记录。
禁止把旧工作区整体压缩后直接上传。发布前应再次检查 Git 暂存文件与所有 Release 资产，
并核对 SHA256SUMS。额外的私有敏感词列表可通过检查脚本的 --extra-terms-file 传入；
该列表应存放在仓库外，不进入提交。
