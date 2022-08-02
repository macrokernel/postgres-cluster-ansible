# Настройка непрерывного автоматического резервного копирования в хранилище данных S3 на одиночном узле СУБД PostgreSQL

Резервное копирование выполяется неперывно и автоматически посредством сжатия файлов журналов транзакций WAL и загрузки их в хранилище данных S3. Кроме того, один раз в сутки ночью выполняется создание полной копии данных СУБД в хранилище данных S3. Восстановление данных производится из полной копии данных и из файлов журналов тразакций WAL, накопленных с момента создания полной копии данных до заданного момента времени, на который требуется восстановление данных.  


## Порядок настройки автоматического резервного копирования
Для краткости будем считать, что системная служба СУБД PostgreSQL называется **postgresql**, работает под учётной записью пользователя **postgres**, а данные СУБД PostgreSQL хранятся в каталоге _/var/lib/postgresql/data_.


### Подготовка к настройке
Перед настройкой резервного копирования необходимо создать бакет в хранилище данных S3 и ключи для доступа к бакету (AWS_ACCESS_KEY_ID и AWS_SECRET_ACCESS_KEY).


### Установка WAL-G
Для установки программы резервного копирования и восстановления WAL-G следует выполнить команды
```shell
curl -L https://github.com/wal-g/wal-g/releases/download/v2.0.0/wal-g-pg-ubuntu-20.04-amd64.tar.gz > /tmp/walg.tar.gz
tar -zxvf /tmp/walg.tar.gz
mv wal-g-* /usr/local/bin/wal-g
chmod +x /usr/local/bin/wal-g
rm /tmp/walg.tar.gz
```


### Создание файла конфигурации WAL-G
Создать файл конфигурации WAL-G _/var/lib/postgresql/walg.json_ следующего содержания:
```json
{
    "PGDATA": "/var/lib/postgresql/data",
    "PGHOST": "/var/run/postgresql",

    "AWS_REGION": "ru-central1",
    "AWS_ENDPOINT": "https://storage.yandexcloud.net/",
    "AWS_ACCESS_KEY_ID": "{{ s3_access_key }}",
    "AWS_SECRET_ACCESS_KEY": "{{ s3_secret_key }}",
    "AWS_S3_FORCE_PATH_STYLE": "true",
    "WALG_S3_PREFIX": "s3://backups/postgres/mydatabase",

    "WALG_PREFETCH_DIR": "/var/lib/postgresql/walg_prefetch",
    "WALG_COMPRESSION_METHOD": "brotli",
    "WALG_DELTA_MAX_STEPS": "5",
    "WALG_UPLOAD_CONCURRENCY": 2,
    "WALG_DOWNLOAD_CONCURRENCY": 2,
    "WALG_UPLOAD_DISK_CONCURRENCY": 2
}
```
Установить владельца файла и задать права доступа, выполнив команду
```shell
chown postgres:postgres /var/lib/postgresql/walg.json
chmod 0600 /var/lib/postgresql/walg.json
```


### Настройка PostgreSQL
Добавить в файл конфигурации PostgreSQL следующие параметры:
```
archive_command = 'wal-g --config /var/lib/postgresql/walg.json wal-push "%p"'
archive_mode = 'on'
archive_timeout = '1800s'
wal_level = 'replica'
```


### Создание файла конфигурации планировщика задач cron
Отредактировать файл конфигурации планировщика задач cron пользователя  **postgres**, выполнив команду
```shell
sudo -u postgres crontab -e
```
и добавить в него строки:
```crontab
# Backup PostgreSQL data
20 5 * * * wal-g --config /var/lib/postgresql/walg.json backup-push /var/lib/postgresql/data 2>&1 | /usr/bin/logger -t wal-g && wal-g --config /var/lib/postgresql/walg.json delete retain FULL 7 --confirm 2>&1 | /usr/bin/logger -t wal-g
```


## Порядок резервного копирования и восстановления

### Резервное копирование по требованию в S3
1. Если активность записи на ведущем узле кластера СУБД невысока, то чтобы в архив попало как можно больше последних данных, перед созданием резервной копии данных СУБД имеет смысл выполнить переключение сегмента журнала WAL при помощи команды
```shell
sudo -u postgres psql -c 'select pg_switch_wal();'
```
2. Затем выполнить архивирование и загрузку данных СУБД в хранилище S3 при помощи команды
```shell
sudo -u postgres wal-g --config /var/lib/postgresql/walg.json backup-push /var/lib/postgresql/data
```
3. После чего выполнить удаление устаревших архивов и журналов WAL из хранилища S3 при помощи команды
```shell
sudo -u postgres wal-g --config /var/lib/postgresql/walg.json delete retain FULL 7
```
Дополнительная информация о команде `wal-g backup-push`: https://github.com/wal-g/wal-g/blob/master/docs/PostgreSQL.md#backup-push  
Дополнительная информация о команде `wal-g delete`: https://github.com/wal-g/wal-g#delete


### Восстановление из резервной копии S3
1. Получить перечень полных резервных копий данных СУБД можно при помощи команды
```shell
sudo -u postgres wal-g --config /var/lib/postgresql/walg.json backup-list
```
2. Получить перечень сегментов журналов WAL с группировкой по таймлайнам можно при помощи команды
```shell
sudo -u postgres wal-g --config /var/lib/postgresql/walg.json wal-show
```
3. Остановить службу **postgresql**.
4. Если позводяет место на диске, создать резервную копию каталога данных PostgreSQL. Если места на диске недостаточно, по меньшей мере сохранить каталог _pg_wal_, который может содержать журналы транзакций, который ещё не были заархивированы на момент выключения СУБД.
5. Удалить каталог данных PostgreSQL.
6. Загрузить резервную копию данных СУБД из хранилища S3, выполнив команду
```shell
sudo -u postgres wal-g backup-fetch /var/lib/postgresql/data LATEST --config /var/lib/postgresql/walg.json
```
7. При необходимости скопировать каталог _pg_wal_, сохранённый на шаге 4. в каталог _data_.
8. Если в файле конфигурации СУБД PostgreSQL определён параметр **hot_standby**, установить его в значение **off**.
9. Если необходим возврат к состоянию данных СУБД на определённый момент времени (PITR), то следует задать требуемое время в значении параметра **recovery_target_time** в файле конфигурации СУБД PostgreSQL, например:
```
recovery_target_time = "2022-05-17 10:00:00.000"
```  
Если требуется восстановление последнего состояния данных СУБД, параметр **recovery_target_time** следует оставить пустым или неопределённым.

10. При необходимости восстановления данных из таймлайна, отличного от последнего, следует также задать параметр **recovery_target_timeline** в файле конфигурации СУБД PostgreSQL.
11. В файл конфигурации СУБД PostgreSQL добавить параметры:
```
recovery_target_action = 'promote'
restore_command = 'wal-g --config /var/lib/postgresql/walg.json wal-fetch "%f" "%p"'
```
12. Создать файл _/var/lib/postgresql/data/recovery.signal_, выполнив команду
```shell
sudo -u postgres touch /var/lib/postgresql/data/recovery.signal
```
13. Запустить службу **postgresql**.
14. Дождаться завершения загрузки и воcстановления данных СУБД PostgreSQL.
15. Проверить целостность данных СУБД.
16. Если на шаге 8 в файле конфигурации СУБД PostgreSQL был изменён параметр **hot_standby**, вернуть его исходное значение.
17. Из файла конфигурации СУБД PostgreSQL удалить (или закомментировать) параметры **recovery_target_time**, **recovery_target_timeline**, **recovery_target_action**, **restore_command**.
18. Перезапустить службу **postgresql**.


### Резервное копирование по требованию на удалённую машину по SSH
1. Аутентификация по публичному ключу не поддерживается WAL-G. Поэтому на машине, куда будет загружена резервная копия данных СУБД (далее по тексу - целевая машина), следует убедиться, что в файле конфигурации сервера SSH _/etc/ssh/sshd_config_ установлен параметр, разрешающий аутентификацию по паролю:
```
PasswordAuthentication yes
```
2. На **ведущем** узле кластера СУБД создать файл конфигурации WAL-G _/opt/patroni/postgres/walg-ssh.json_ следующего содержания:
```json
{
    "PGDATA": "/var/lib/postgresql/data",
    "PGHOST": "/var/run/postgresql",

    "WALG_SSH_PREFIX": "ssh://{{hostname}}:/home/{{username}}/pg-backup",
    "SSH_PORT": "22",
    "SSH_USERNAME": "{{username}}",
    "SSH_PASSWORD": "{{password}}",

    "WALG_PREFETCH_DIR": "/var/lib/postgresql/walg_prefetch",
    "WALG_COMPRESSION_METHOD": "brotli",
    "WALG_DELTA_MAX_STEPS": "5",
    "WALG_UPLOAD_CONCURRENCY": 2,
    "WALG_DOWNLOAD_CONCURRENCY": 2,
    "WALG_UPLOAD_DISK_CONCURRENCY": 2
}
```
При этом вместо `{{hostname}}`, `{{username}}`, `{{password}}` следует подставить адрес, имя пользователя и пароль целевой машины.
3. Затем установить права доступа к созданному файлу, выполнив команду
```shell
chmod 644 /opt/patroni/postgres/walg-ssh.json
```
4. На целевой машине создать каталог, куда будет загружена резервная копия данных СУБД, определяемый значением параметра **WALG_SSH_PREFIX** в файле конфигурации WAL-G _/opt/patroni/postgres/walg-ssh.json_.
5. Проверить подключение по протоколу SSH с ведущего узла кластера СУБД к целевой машине и подтвердить подлинность сетевого узла, выполнив на ведущем узле кластера СУБД команду
```shell
$ docker exec -it patroni ssh {{username}}@{{hostname}}
The authenticity of host '{{hostname}} ({{hostname}})' cant be established.
ECDSA key fingerprint is SHA256:QDgzfYzghTY3gnjJpgQWCszNZPmz4eC6zs7Vy89swF0.
Are you sure you want to continue connecting (yes/no/[fingerprint])? yes
```
6. Запустить резервное копирование данных СУБД, выполнив на ведущем узле кластера СУБД команду
```shell
docker exec -it patroni wal-g --config /var/lib/postgresql/walg-ssh.json backup-push /var/lib/postgresql/data
```


### Восстановление из резервной копии с удалённой машины по SSH
Восстановление из резервной копии с удалённой машины по SSH производится аналогично восстановлению из резервной копии S3 за исключением того, что во всех командах WAL-G следует указывать файл конфигурации WAL-G с параметрами доступа по SSH: _/opt/patroni/postgres/walg-ssh.json_.

### Проверка данных после восстановления <a name="restore_check"/>
После восстановления данных СУБД из резервной копии необходимо, по меньшей мере, проверить целостность данных и индексов. Желательно настроить автоматическую проверку последней созданной резервной копии данных после завершения процедуры ежедневного резервного копирования путём восстановления данных из резервной копии на тестовый сервер.  

Для проверки целостности данных достаточно сделать дамп базы. Желательно также, чтобы при инициализации базы данных были включены контрольные суммы: https://postgrespro.ru/docs/postgresql/14/app-initdb#APP-INITDB-DATA-CHECKSUMS.  

Пример сценария проверки целостности данных СУБД:
```shell
if ! sudo -u postgres pg_dumpall > /dev/null; then
    echo 'pg_dumpall failed' >&2
    exit 125
fi
```

Проверка индексов может быть выполнена при помощи модуля PostgreSQL **amcheck**: https://postgrespro.ru/docs/postgrespro/14/amcheck.  

Сначала следует создать файл проверочного SQL-запроса _/tmp/amcheck.sql_ следующего содержания:
```sql
CREATE EXTENSION IF NOT EXISTS amcheck;
SELECT bt_index_check(c.oid), c.relname, c.relpages
FROM pg_index i
JOIN pg_opclass op ON i.indclass[0] = op.oid
JOIN pg_am am ON op.opcmethod = am.oid
JOIN pg_class c ON i.indexrelid = c.oid
JOIN pg_namespace n ON c.relnamespace = n.oid
WHERE am.amname = 'btree'
AND c.relpersistence != 't'
AND i.indisready AND i.indisvalid;
```
и установить владельца созданного файла - **postgres**, выполнив команду
```shell
chown postgres /tmp/amcheck.sql
```
Затем следует создать сценарий запуска проверок всех доступных баз в СУБД _/tmp/amcheck.sh_ следующего содержания:
```shell
for DBNAME in $(psql -q -A -t -c "SELECT datname FROM pg_database WHERE datistemplate = false;"); do
    echo "Database: ${DBNAME}"
    psql -f /tmp/amcheck.sql -v 'ON_ERROR_STOP=1' ${DBNAME} && EXIT_STATUS=$? || EXIT_STATUS=$?
    if [ "${EXIT_STATUS}" -ne 0 ]; then
        echo "amcheck failed on DB: ${DBNAME}" >&2
        exit 125
    fi
done
```
и сделать его исполняемым, выполнив команду
```shell
chmod +x /tmp/amcheck.sh
```
После чего запустить сценарий проверки, выполнив команду
```shell
sudo -u postgres /tmp/amcheck.sh >/dev/null
```
В случае ошибки сценарий выдаст сообщение об ошибке, содержащее имя базы данных, с которой есть проблемы, и завершится с кодом возврата, отличным от ``0``.


## Дополнительная информация
1. WAL-G: бэкапы и восстановление СУБД PostgreSQL - https://habr.com/en/post/506610/
