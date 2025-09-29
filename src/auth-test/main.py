from fastapi import FastAPI, Depends
from fastapi.responses import HTMLResponse
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
import jwt
import os
from typing import Optional

app = FastAPI()

# JWT 설정
SECRET_KEY = os.getenv("JWT_SECRET_KEY", "your-secret-key-change-this-in-production")
ALGORITHM = "HS256"

security = HTTPBearer(auto_error=False)


def verify_token(credentials: Optional[HTTPAuthorizationCredentials] = Depends(security)) -> Optional[dict]:
    if credentials is None:
        return None
    try:
        token = credentials.credentials
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        username: str = payload.get("sub")
        if username is None:
            return None
        return {"username": username}
    except jwt.PyJWTError as e:
        print(e)
        return None


@app.get("/", response_class=HTMLResponse)
async def root(user_info: Optional[dict] = Depends(verify_token)) -> HTMLResponse:
    if user_info:
        html_content = f"""
        <!DOCTYPE html>
        <html>
        <body style="background-color: black;">
            <div style="background-color: black; display: flex; justify-content: center; align-items: center; height: 100vh;">
                <h1 style="color: white; font-family: 'Montserrat', sans-serif;">Welcome, {user_info['username']}!</h1>
            </div>
        </body>
        </html>
        """
    else:
        html_content = """
        <!DOCTYPE html>
        <html>
        <body style="background-color: black;">
            <div style="display: flex; justify-content: center; align-items: center; height: 100vh;">
                <h1 style="color: white; font-family: 'Montserrat', sans-serif;">You are not logged in</h1>
            </div>
        </body>
        </html>
        """
    return HTMLResponse(content=html_content)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
