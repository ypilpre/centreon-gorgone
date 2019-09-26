# Action

## Description

This module aims to execute actions on the server running the Gorgone daemon or remotly using SSH.

## Events

| Event | Description |
| :- | :- |
| ACTIONREADY | Internal event to notify the core |
| PROCESSCOPY | Process file or archive received from another daemon |
| COMMAND | Execute a shell command on the server running the daemon or on another server using SSH |

## API

### Execute a Command Line

| Endpoint | Method |
| :- | :- |
| /api/core/action/command | `POST` |

Headers

---

| Header | Value |
| :- | :- |
| Accept | application/json |
| Content-Type | application/json|

Body

---

```json
{
    "command": "<command to execute>"
}
```

#### Example

```bash
curl --request POST "https://hostname:8443/api/core/action/command" \
  --header "Accept: application/json" \
  --header "Content-Type: application/json" \
  --data "{
    \"command\": \"echo 'Test command' >> /tmp/here.log\"
}"
```