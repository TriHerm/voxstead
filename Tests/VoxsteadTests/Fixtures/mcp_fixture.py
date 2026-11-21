import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


def reply(request):
    method = request["method"]
    if "id" not in request:
        return None
    if method == "initialize":
        value = {
            "protocolVersion": request["params"]["protocolVersion"],
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "fixture", "version": "1"},
        }
    elif method == "tools/list":
        value = {"tools": [{
            "name": "echo",
            "description": "Echo a word",
            "inputSchema": {"type": "object", "properties": {"word": {"type": "string"}}},
        }]}
    elif method == "tools/call":
        word = request["params"]["arguments"]["word"]
        value = {
            "content": [{"type": "text", "text": word}],
            "structuredContent": {"echo": word},
        }
    else:
        return dict(jsonrpc="2.0", id=request["id"], error=dict(code=-32601, message="Unknown method"))
    return dict(jsonrpc="2.0", id=request["id"], result=value)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("x-api-key") == "catalog-key":
            if self.headers.get("anthropic-version") != "2023-06-01":
                self.send_error(400)
                return
            result = ({"data": [{"id": "claude-b"}], "has_more": False}
                      if "after_id=claude-a" in self.path else
                      {"data": [{"id": "claude-a"}], "has_more": True, "last_id": "claude-a"})
        elif self.headers.get("Authorization") == "Bearer catalog-key":
            result = {"data": [{"id": "chat-b"}, {"id": "chat-a"}, {"id": "chat-a"}]}
        else:
            self.send_error(401)
            return
        if not self.path.startswith("/v1/models"):
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(result).encode())

    def do_POST(self):
        if self.path == "/v1/chat/completions":
            self.respond_as_model()
            return
        if self.path != "/mcp" or self.headers.get("Authorization") != "Bearer fixture-token":
            self.send_error(401)
            return
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if request["method"] != "initialize" and self.headers.get("Mcp-Session-Id") != "fixture-session":
            self.send_error(400)
            return
        result = reply(request)
        self.send_response(202 if result is None else 200)
        self.send_header("Content-Type", "application/json")
        if request["method"] == "initialize":
            self.send_header("Mcp-Session-Id", "fixture-session")
        self.end_headers()
        if result is not None:
            self.wfile.write(json.dumps(result).encode())

    def respond_as_model(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        turns = request["messages"]
        question = turns[-1]["content"]
        language_cases = {
            "Acordamos entregar el diseño mañana.": "Entregaremos el diseño mañana.",
            "Nous avons décidé de livrer le dessin demain.": "Le dessin sera livré demain.",
            "明日デザインを提出することに決まりました。": "明日デザインを提出します。",
        }
        language_answer = next((answer for text, answer in language_cases.items() if text in question), None)
        if language_answer:
            system = "\n".join(turn.get("content", "") for turn in turns if turn["role"] == "system")
            if ("Summary and Catch me up must stay in the spoken language" not in system
                    or "For catch-up questions, explain the recent discussion in that preferred language" in system):
                self.send_error(400, "Missing or conflicting meeting-language policy")
                return
            message = {"content": json.dumps({"summary": language_answer, "decisions": [], "tasks": []})
                       if 'Produce {"summary":' in question else language_answer}
        elif turns[-1]["role"] == "tool":
            message = {"content": question}
        elif request["model"] == "catch-up-fixture":
            original = "opening-checkpoint" in question
            delayed = "late-finalized-speech" in question
            if "simulate-failed-recap" in question:
                self.send_error(503, "Simulated network failure")
                return
            if "since the last successful recap" in question:
                if original or not delayed:
                    self.send_error(400, "Expected only newly finalized speech")
                    return
                message = {"content": "New speech recap."}
            elif original:
                message = {"content": "Full recap." if delayed else "Opening recap."}
            else:
                self.send_error(400, "Expected the opening transcript")
                return
        elif request["model"] == "long-catch-up-fixture":
            markers = ["first-marker", "middle-marker", "last-marker"]
            observed = [marker for marker in markers if marker in question]
            if question.startswith("Current request:"):
                if observed != markers:
                    self.send_error(400, "The recap skipped part of the transcript")
                    return
                message = {"content": "All three parts reviewed."}
            else:
                message = {"content": "Notes: " + ", ".join(observed)}
        elif request["model"] == "meeting-prep-fixture":
            if ("User's preparation notes:" not in question or "Confirm the next review" not in question
                    or "Transcript excerpt:" in question or request.get("tools")):
                self.send_error(400, "Preparation must use notes only and no external tools")
                return
            message = {"content": "Ask who owns the next review."}
        elif request["model"] == "quick-reply-fixture":
            system = turns[0]["content"]
            include_meaning = "meaning in English" in system
            if (not all(phrase in question for phrase in (
                    "Aprobamos el presupuesto de 8,000", "¿Cómo confirmamos el presupuesto", "Design review is on Thursday"
                )) or "unrelated opening" in question or "later custom answer" in question
                    or "language of the latest substantive turn" not in system
                    or (not include_meaning and "Set meaning to null" not in system)
                    or request.get("tools")):
                self.send_error(400, "Expected a reply grounded in current speech and relevant earlier context")
                return
            message = {"content": json.dumps({
                "sentence": "¿Podemos confirmar los 8,000 acordados para el prototipo?",
                "meaning": "Can we confirm the 8,000 we agreed on for the prototype?" if include_meaning else None,
            })}
        elif request["model"] == "phone-reply-fixture":
            system = turns[0]["content"]
            if (not all(phrase in question for phrase in (
                    "Can you commit to Friday?", "Goal: ask about delivery.", "No date commitments",
                    "may include provisional text"
                )) or "Earlier discussion 1." in question or request.get("tools")
                    or "English (United States)" not in system or "meaning in Spanish" not in system
                    or "Keep the user's limits" not in system or "speaker identity is uncertain" not in system):
                self.send_error(400, "Expected recent speech, full prep notes and explicit limits")
                return
            message = {"content": json.dumps({
                "sentence": "Could I check with my team and get back to you?",
                "meaning": "¿Puedo consultarlo con mi equipo y luego avisarle?",
            })}
        elif request["model"] == "phone-recap-fixture":
            if (not all(phrase in question for phrase in (
                    'batch A for Thursday', '"dates"', '"requirements"', "only explicit agreements",
                    "details still needing confirmation"
                )) or "Tuesday" in question or request.get("tools")):
                self.send_error(400, "Expected a recap of the finished transcript")
                return
            message = {"content": json.dumps({
                "summary": "The shipment was confirmed and still needs the proof.",
                "decisions": ["Ship batch A."],
                "dates": ["Thursday · confirmed shipment"],
                "requirements": ["Proof still needed."],
                "tasks": [{"title": "Send the checklist", "owner": None, "due": None}],
            })}
        elif request["model"] == "task-match-fixture":
            if "BEGIN EXISTING TASKS" not in question:
                self.send_error(400, "Missing task references")
                return
            references = json.loads(question.split("BEGIN EXISTING TASKS", 1)[1].split("END EXISTING TASKS", 1)[0])
            existing_id = next(task["id"] for task in references if task["title"] == "Send the draft")
            message = {"content": json.dumps({
                "summary": "El borrador se envía mañana.",
                "decisions": [],
                "tasks": [{"title": "Enviar el borrador", "owner": "Ana", "due": "mañana", "existingTaskID": existing_id}],
            })}
        elif request["model"] == "long-debrief-fixture":
            markers = ["first-marker", "middle-marker", "last-marker"]
            observed = [marker for marker in markers if marker in question]
            message = {"content": json.dumps({"summary": "Reviewed transcript",
                       "decisions": observed, "tasks": []})}
        elif 'Produce {"summary":' in question:
            message = {"content": json.dumps({
                "summary": "The draft is due tomorrow.",
                "decisions": ["Send the draft tomorrow."],
                "tasks": [{"title": "Send the draft", "owner": None, "due": "tomorrow"}],
            })}
        elif 'Review this communication habit:' in question:
            message = {"content": json.dumps({
                "observation": "The date was clear. Name who owns the task.",
                "quote": "We agreed to send the draft tomorrow.",
                "suggestion": "I will send the draft tomorrow.",
            })}
        elif 'Meeting excerpts' in question:
            message = {"content": "The draft is due tomorrow [1]."}
        else:
            tool_name = request["tools"][0]["function"]["name"]
            message = {"content": None, "tool_calls": [{
                "id": "call_1",
                "type": "function",
                "function": {"name": tool_name, "arguments": json.dumps({"word": "hola"})},
            }]}
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"choices": [{"message": message}]}).encode())

    def do_DELETE(self):
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "http":
        with HTTPServer(("127.0.0.1", 0), Handler) as server:
            print(server.server_port, flush=True)
            server.serve_forever()
    else:
        for line in sys.stdin:
            result = reply(json.loads(line))
            if result is not None:
                print(json.dumps(result), flush=True)
