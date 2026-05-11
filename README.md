rezka client for bazzite/steamos

## Linux: AppImage (релиз на GitHub)

**Тег в git и страница Releases на GitHub — разные вещи.** Архивы zip/tar.gz на вкладке тега создаёт сам GitHub; AppImage появится только если отработал workflow и он смог создать **Release**.

1. Убедитесь, что коммит, который тегируете, уже содержит `.github/workflows/release-linux.yml` (иначе при `git push --tags` workflow не запустится).
2. В репозитории: **Settings → Actions → General → Workflow permissions** — включите **Read and write permissions** (иначе `gh release create` не сможет создать релиз).
3. Создайте тег и отправьте его: `git tag v1.0.0 && git push origin v1.0.0` (подойдёт и тег без префикса `v`, например `1.0.0`).
4. Откройте **Actions**: должен быть зелёный прогон **Release (Linux AppImage)**. Файл AppImage ищите на странице **`https://github.com/<user>/<repo>/releases`** (блок **Assets**), а не на странице одного тега — там GitHub по умолчанию только zip/tar исходников.

**Если после `git push origin v1.0.x` в Actions пусто или нет релиза:**

- Проверьте, что в **том же коммите, что и тег**, есть workflow (и что этот коммит запушен на GitHub):

  ```bash
  git fetch origin
  git show v1.0.1:.github/workflows/release-linux.yml
  ```

  Ошибка `fatal: path does not exist` → тег указывает на старый коммит без CI. Сделайте новый коммит с workflow, запушьте ветку, затем новый тег.

- Убедитесь, что вы запушили **ветку** с этим коммитом, а не только тег: `git push origin main` (или ваша ветка по умолчанию).

- **Уже есть тег, но релиза нет:** на GitHub откройте **Actions → Release (Linux AppImage) → Run workflow**:
  - `git_ref`: `v1.0.1`
  - `publish_to_release`: включите (true)  
  После успешного прогона появится Release с AppImage.

Локально: установите [зависимости сборки](requirements-linux-build.txt), затем:

```bash
pyinstaller rezka-native.spec
chmod +x packaging/linux/build-appimage.sh
REZKA_VERSION=1.0.0 packaging/linux/build-appimage.sh
```

Нужны `librsvg2-bin` (иконка PNG) и `wget`. Запуск AppImage: `chmod +x *.AppImage && ./rezka-native-*.AppImage`.

Ручная проверка CI без тега: **Actions → Release (Linux AppImage) → Run workflow** — артефакт появится в summary.

## Linux: Flatpak (локальная сборка)

Из корня репозитория (при необходимости смените `app-id` в манифесте):

```bash
flatpak-builder --user --install-deps-from=flathub --force-clean build-dir packaging/flatpak/app.rezka.RezkaNative.yml
flatpak run app.rezka.RezkaNative
```