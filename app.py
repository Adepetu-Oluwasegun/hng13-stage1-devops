from flask import Flask

app = Flask(__name__)

@app.route("/")
def home():
    return "This is Oluwasegun Adepetu's HNG 13 stage 1 task."

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)