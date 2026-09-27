# Динамическое масштабирование InsureTech

Учебный стенд проверяет горизонтальное масштабирование тестового приложения: Kubernetes добавляет или удаляет одинаковые поды в зависимости от нагрузки. В первой части HPA (Horizontal Pod Autoscaler, контроллер количества реплик) использует память, во второй — среднее число запросов в секунду (RPS) на под. Проверяется приложение `scaletestapp`; базы данных в этом стенде нет.

## Состав и параметры

| Файл | Назначение |
| --- | --- |
| `namespace.yaml` | Изолированное пространство имён `task2` |
| `deployment.yaml` | Одна начальная реплика, порт 8080, лимит памяти 30 MiB |
| `service.yaml` | NodePort 30080, распределяющий запросы по готовым подам |
| `hpa-memory.yaml` | Память: 80% от запроса памяти, от 1 до 10 реплик |
| `hpa-rps.yaml` | Запросы: в среднем 10 RPS на под, от 1 до 10 реплик |
| `prometheus.yaml` | Prometheus, автоматическое обнаружение подов и сбор `/metrics` |
| `adapter-values.yaml`, `install-adapter.sh` | Prometheus Adapter 0.12.0, chart 5.3.0, публикация RPS в Kubernetes |
| `locustfile.py`, `requirements.txt` | Нагрузочный сценарий: `GET /`, паузы 1–5 секунд |
| `run-experiment.sh` | Полный прогон с минутой простоя, четырьмя минутами нагрузки и наблюдением после неё |
| `capture.sh` | Запись времени, HPA, реплик, памяти и перезапусков |
| `arm64/` | Неизменённые исходники приложения и patch для локальной сборки ARM64 |
| `evidence/` | Фактические логи, CSV и скриншоты испытаний |

Оба HPA имеют одинаковое имя `scaletestapp`: применение второго файла **заменяет** метрику первого. Два независимых контроллера одного Deployment не создаются. Не применяйте весь каталог рекурсивно: этапы и ARM64 patch требуют указанного ниже порядка.

Проверки готовности и работоспособности открывают TCP-соединение к порту 8080. Они не вызывают `GET /` и не увеличивают счётчик пользовательских запросов. Prometheus запрашивает `/metrics`, который также не увеличивает этот счётчик.

## 1. Отдельный кластер и приложение

Команды выполняются из корня репозитория. Требуются Docker, Minikube, kubectl, Helm 3 и Python с venv/pip. Используется отдельный профиль; все команды kubectl явно указывают его контекст.

```bash
minikube start -p insuretech-task2 --driver=docker --cpus=2 --memory=3072 --kubernetes-version=v1.35.1 --keep-context
minikube -p insuretech-task2 addons enable metrics-server
kubectl --context=insuretech-task2 -n kube-system rollout status deployment/metrics-server --timeout=180s
kubectl --context=insuretech-task2 apply -f Task2/namespace.yaml
kubectl --context=insuretech-task2 apply -f Task2/deployment.yaml -f Task2/service.yaml
```

На ARM64 перед ожиданием готовности приложения выполните [локальную сборку и patch](arm64/README.md). Официальный образ из задания доступен для AMD64; ошибка `no matching manifest for linux/arm64/v8` не связана с HPA.

```bash
kubectl --context=insuretech-task2 -n task2 rollout status deployment/scaletestapp --timeout=180s
kubectl --context=insuretech-task2 apply -f Task2/hpa-memory.yaml
kubectl --context=insuretech-task2 -n task2 top pods
kubectl --context=insuretech-task2 -n task2 get hpa
```

В сохранённых испытаниях обеих частей Prometheus уже был включён. Для точного повторения сначала выполните установку из раздела 3, затем вернитесь к испытанию памяти в разделе 2. Сам HPA по памяти от Prometheus не зависит.

После запуска сбор метрик занимает некоторое время. До первого измерения `<unknown>` допустим; длительное отсутствие метрик требует проверки `kubectl --context=insuretech-task2 -n task2 describe hpa scaletestapp` и логов metrics-server.

## 2. Проверка масштабирования по памяти

В Deployment выбран `requests.memory: 12Mi`, поэтому целевое среднее потребление равно `12 × 0,8 = 9,6 MiB`. Запрос памяти подобран для локального образа с включённым Prometheus; это параметр учебного стенда, требующий повторной проверки для другого образа или архитектуры процессора. Слишком низкое значение вызывает рост реплик даже в простое, слишком высокое — не достигается нагрузкой. HPA по памяти может срабатывать после завершения запросов, поскольку память Go-процесса освобождается не сразу; этот режим не гарантирует своевременную защиту от перегрузки.

HPA сравнивает потребление с `requests.memory`, а не с `limits.memory`. Лимит 30 MiB ограничивает потребление контейнера, но сам по себе не задаёт момент масштабирования. Подробности алгоритма — в [документации Kubernetes](https://kubernetes.io/docs/concepts/workloads/autoscaling/horizontal-pod-autoscale/).

На Linux с драйвером Docker адрес приложения можно получить так:

```bash
minikube -p insuretech-task2 service scaletestapp -n task2 --url
```

Используйте выведенный адрес в Locust. На платформах, где Minikube создаёт туннель, оставьте эту команду работающей. Не заменяйте адрес на `kubectl port-forward svc/scaletestapp`: он выбирает один под на всё время соединения и не проверяет балансировку между репликами.

Подготовьте нагрузочный инструмент:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r Task2/requirements.txt
.venv/bin/locust -f Task2/locustfile.py
```

В [Locust](http://localhost:8089) укажите адрес приложения, 3000 пользователей и скорость появления 100 пользователей/с. Запустите нагрузку на 4 минуты. Пауза 1–5 секунд даёт примерно 1000 RPS при малой задержке ответа. Число пользователей не равно RPS. Заголовок `Connection: close` в сценарии создаёт новые соединения, чтобы Service мог распределять запросы между новыми подами.

Для автоматического прогона и записи доказательств используйте два терминала. Вместо `APP_URL` подставьте адрес из команды Minikube. Здесь и далее префикс `repeat-` сохраняет исходные результаты отдельно.

```bash
bash Task2/capture.sh memory 28 > Task2/evidence/repeat-memory-scaling.log 2>&1
```

```bash
.venv/bin/locust -f Task2/locustfile.py --headless --host APP_URL \
  -u 3000 -r 100 -t 4m --only-summary \
  --csv Task2/evidence/repeat-memory --csv-full-history \
  > Task2/evidence/repeat-memory-locust.log 2>&1
```

Автоматизированный вариант обеих команд с минутой исходного наблюдения:

```bash
bash Task2/run-experiment.sh memory APP_URL 3000 100
```

Он перезаписывает файлы `evidence/memory-*`, поэтому используйте его для намеренного повторения, предварительно сохранив нужные старые результаты. `memory-initial-*` и `memory-request8-idle.log` остаются отдельными предварительными замерами.

Запустите сбор наблюдений до нагрузки. После её остановки продолжайте наблюдение: память процесса может освобождаться медленно. Успешное испытание роста требует события `SuccessfulRescale` с причиной `memory resource utilization` и нескольких готовых реплик. Ручное изменение `replicas` доказательством работы HPA не является.

## 3. Prometheus и метрика RPS

```bash
kubectl --context=insuretech-task2 apply -f Task2/prometheus.yaml
kubectl --context=insuretech-task2 -n task2 rollout status deployment/prometheus --timeout=180s
bash Task2/install-adapter.sh
kubectl --context=insuretech-task2 get apiservice v1beta1.custom.metrics.k8s.io
```

Установка адаптера использует Helm для генерации манифестов и kubectl для применения. Скрипт явно включает актуальную версию ресурса `APIService`; это не Helm release. Prometheus имеет права только читать сведения о подах в `task2`. Адаптеру нужны кластерные права для публикации Custom Metrics API.

Цепочка измерения:

```text
scaletestapp /metrics → Prometheus → Prometheus Adapter
                                    ↓
                         custom.metrics.k8s.io → HPA → Deployment
```

Prometheus каждые 15 секунд обнаруживает готовые поды с `app=scaletestapp` и опрашивает каждый напрямую. В метрику добавляются `namespace` и `pod`; запрос через общий Service вместо отдельных подов не позволил бы надёжно различать реплики. [Настройка обнаружения Kubernetes](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#kubernetes_sd_config).

Адаптер публикует `http_requests_per_second` из выражения:

```promql
sum by (namespace, pod) (
  rate(http_requests_total{namespace="task2",job="scaletestapp"}[1m])
)
```

`http_requests_total` — накопительный счётчик. Функция `rate` преобразует его прирост за минуту в запросы/с и учитывает сброс счётчика при перезапуске. Сначала вычисляется скорость каждого ряда, затем сумма по поду. [Семантика rate](https://prometheus.io/docs/prometheus/latest/querying/functions/#rate), [конфигурация адаптера](https://github.com/kubernetes-sigs/prometheus-adapter/blob/master/docs/config.md).

Для проверки интерфейса:

```bash
kubectl --context=insuretech-task2 -n task2 port-forward svc/prometheus 9090:9090
```

Откройте [Prometheus](http://localhost:9090). В Query выполните `http_requests_total{job="scaletestapp"}`; затем приведённый выше запрос скорости. Вкладка Graph покажет изменение во времени, Status → Target health — состояние `UP` для подов. В новых версиях интерфейса название страницы запросов — Query. Сохраните скриншоты в `Task2/evidence/`. Примеры проверяемых представлений: [счётчик](evidence/prometheus-counter.png), [состояние targets](evidence/prometheus-targets.png), [RPS на под](evidence/prometheus-rps-table.png) и [график RPS](evidence/prometheus-rps-graph.png).

Проверьте путь от адаптера до API Kubernetes:

```bash
kubectl --context=insuretech-task2 get --raw '/apis/custom.metrics.k8s.io/v1beta1/namespaces/task2/pods/*/http_requests_per_second'
```

Ответ должен содержать элементы с именами подов. Значение `15000m` означает 15 запросов/с: `m` здесь — тысячная доля единицы, а не миллисекунды.

## 4. Проверка масштабирования по RPS

Остановите предыдущую нагрузку. Примените новый вариант HPA и дождитесь сокращения до одной готовой реплики при нулевом RPS:

```bash
kubectl --context=insuretech-task2 apply -f Task2/hpa-rps.yaml
kubectl --context=insuretech-task2 -n task2 get hpa -w
```

`AverageValue: 10` — выбранный для демонстрации порог 10 RPS на под; в условии числовой порог не задан. При общей нагрузке около 50 RPS ожидается около пяти подов. Контроллер допускает небольшое отклонение, учитывает готовность и отсутствие измерений новых реплик; точное число в каждый момент не гарантируется.

В двух терминалах:

```bash
bash Task2/capture.sh rps 28 > Task2/evidence/repeat-rps-scaling.log 2>&1
```

```bash
.venv/bin/locust -f Task2/locustfile.py --headless --host APP_URL \
  -u 150 -r 15 -t 4m --only-summary \
  --csv Task2/evidence/repeat-rps --csv-full-history \
  > Task2/evidence/repeat-rps-locust.log 2>&1
```

Автоматизированный вариант: `bash Task2/run-experiment.sh rps APP_URL 150 15`. Он перезаписывает файлы `evidence/rps-*`.

Дождитесь роста, сохраните результат Custom Metrics API, HPA и скриншот скорости в Prometheus. После прекращения нагрузки ожидайте нулевой RPS и возврат к одной реплике. Минутное окно `rate`, задержки сбора и 60 секунд стабилизации уменьшения делают реакцию не мгновенной.

## Ограничения стенда

- HPA не предотвращает мгновенный выход за лимит памяти. Если один запрос требует больше 30 MiB, под может завершиться с `OOMKilled` раньше появления реплик; нужны профилирование и ограничение параллельной работы.
- Память простого Go-приложения зависит от сборщика мусора и не обязана уменьшаться пропорционально RPS. Масштабирование по ней может добавлять поды без заметной разгрузки уже работающих; для этого приложения RPS даёт более прямой сигнал.
- Максимум 10 подов не заменяет достаточный запас ресурсов ноды. Этот одноузловой стенд проверяет HPA, но не отказоустойчивость и не готовность реальных сервисов InsureTech к рекламной кампании.
- Prometheus хранит данные в `emptyDir` на два часа: пересоздание пода теряет историю. Скриншоты и выгрузки сохраняются в репозитории. В промышленной среде нужны постоянное хранилище и политика хранения.
- Chart адаптера по умолчанию не проверяет сертификат соединения API server → adapter (`insecureSkipTLSVerify`). Это локальный учебный стенд; для эксплуатации нужны доверенные сертификаты. NodePort также предназначен для локальных испытаний.
- Образ приложения `latest` в исходном условии изменяемый. Версия исходников ARM64 зафиксирована; перед переносом результатов на официальный образ AMD64 испытания нужно повторить.

После завершения можно остановить только новый профиль, сохранив стенд:

```bash
minikube -p insuretech-task2 stop
```

Фактические результаты и оставшиеся вопросы находятся в [общем отчёте, задание 2](../report.md#задание-2-динамическое-масштабирование-контейнеров).
