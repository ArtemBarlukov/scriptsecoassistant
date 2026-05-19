# Bash deployment scripts

Набор скриптов переводит ручное развёртывание Docker-проекта в воспроизводимый сценарий.

Скрипты можно запускать вручную или через Ansible.

## Состав

deploy.yml
inventory.ini
run_ansible_deploy.sh
00_bootstrap_ansible_access.sh
deploy.conf.example
deploy.conf
scripts/
  01_check_server.sh
  02_prepare_server.sh
  03_copy_archives.sh
  04_load_images.sh
  05_restore_db.sh
  06_up_project.sh
  07_check_project.sh
  lib/common.sh

  
## Подготовка
Автоматизированное развёртывание через Ansible:

1. Установить Ansible на управляющей машине.
2. Проверить deploy.conf.
3. Настроить SSH-доступ к целевому серверу:
  bash 00_bootstrap_ansible_access.sh --host <ip-сервера> --port <ssh-порт> --user <пользователь>
4. Запустить Ansible:
  ansible-playbook -i inventory.ini deploy.yml


 Ansible копирует bash-сценарии на целевой сервер и выполняет этапы развёртывания:
– проверка сервера;
– подготовка каталогов;
– перенос конфигураций и Docker-архивов со старого сервера;
– загрузка Docker-образов;
– запуск контейнеров;
– проверка состояния проекта.

Через скрипты
1. Скопировать каталог со скриптами на сервер.
2. Отредактировать `deploy.conf`.
3. Положить проект в каталог `PROJECT_DIR`, например `/opt/ecoassistant`.
4. Положить Docker-архивы образов в `IMAGE_ARCHIVE_DIR`, например `/opt/ecoassistant/images`.
5. Положить dump БД в `DB_DUMP_FILE`, например `/opt/ecoassistant/backups/dump.sql`.
6. Проверить `.env`: реальные токены и пароли не должны оставаться `CHANGE_ME`.

## Типовой запуск
Если установлен Ansible:
bash run_ansible_deploy.sh --host <IP_СЕРВЕРА> --port <SSH_ПОРТ> --user <ПОЛЬЗОВАТЕЛЬ>

Если Ansible не установлен: (bash)
chmod +x run_all.sh scripts/*.sh scripts/lib/common.sh
cp deploy.conf.example deploy.conf
nano deploy.conf

./scripts/01_check_server.sh
./scripts/02_prepare_server.sh
./scripts/03_copy_archives.sh
./scripts/04_load_images.sh
./scripts/05_restore_db.sh
./scripts/06_up_project.sh
./scripts/07_check_project.sh

Для первой установки лучше выполнять скрипты по одному, чтобы видеть результат каждого этапа.

## Что важно настроить в deploy.conf
1. PROJECT_DIR — каталог проекта на новом сервере.
2. PROJECT_USER — пользователь, который владеет каталогом проекта.
3. COMPOSE_FILE — путь к docker-compose.yml.
4. ENV_FILE — путь к .env.
5. IMAGE_ARCHIVE_DIR — каталог с .tar, .tar.gz, .tgz Docker-образами на новом сервере.
6. SOURCE_SERVER_HOST — IP-адрес старого сервера.
7. SOURCE_SERVER_USER — пользователь старого сервера.
8. SOURCE_SERVER_PORT — SSH-порт старого сервера.
9. SOURCE_SERVER_PROJECT_DIR — каталог проекта на старом сервере.
10. SOURCE_SERVER_IMAGE_DIR — каталог Docker-архивов на старом сервере.
11. DB_DUMP_FILE — путь к dump-файлу БД, если используется восстановление.
12. DB_TYPE — postgres, mysql или mariadb.
13. DB_SERVICE — имя сервиса БД.
14. DB_NAME, DB_USER, DB_PASSWORD_ENV_NAME — параметры подключения к БД.
15. CHECK_TABLES — таблицы, по которым нужно проверить COUNT(*) после восстановления.
16. BACKEND_SERVICE — имя backend-сервиса.
17. HTTP_ROOT_URL, FAISS_STATUS_URL, BACKEND_HEALTH_URL — URL для проверки после запуска.
18. RETAG_RULES — правила retag, если после docker load имена образов не совпадают с compose-файлом.

## Безопасность

Скрипты не выводят токены намеренно. Токены и пароли лучше хранить в `.env`, а не в `deploy.conf`.

`02_prepare_server.sh` создаёт `.env` из шаблона только если `.env` ещё нет. Уже существующий `.env` не перезаписывается.

Не рекомендуется копировать сырой каталог БД как обычную директорию. Для переноса БД лучше использовать dump-файл.
Если токен был опубликован в логах, скриншоте, чате или репозитории, его нужно считать скомпрометированным и перевыпустить.

## Ограничения

- Автоматическая установка Docker реализована только для Debian/Ubuntu-подобных систем через `apt`.
- Для PostgreSQL поддерживаются обычные SQL dump-файлы и custom-format dump-файлы `.dump`/`.backup`.
- На серверах без подходящего Python Ansible-playbook использует raw-команды.
- MAX API не имеет универсального health-check endpoint в этих скриптах: нужно указать `MAX_API_CHECK_URL`, если в проекте есть безопасная проверочная точка.
- HTTPS-сертификат не выпускается автоматически: первичный запуск может выполняться только на HTTP-порту 80.
