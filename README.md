# Fissio

Akýllý fiþ iþleme ve mikro harcama yönetimi.

## Backend
```
docker compose up --build
```
- Auth: http://localhost:8081/health
- Expense: http://localhost:8082/health
- PostgreSQL dýþarý açýlmaz (yalnýzca Docker iç aðý).

## Mobil
`fissio_mobile/` içinde: `flutter run`
(Android emülatöründe backend adresi `http://10.0.2.2:8081`)
