(() => {
    const canvas = document.getElementById('canvas-new');
    const ctx = canvas.getContext('2d');
    const host = canvas.parentElement || canvas;

    function resizeCanvas() {
        const rect = host.getBoundingClientRect();
        canvas.width = rect.width;
        canvas.height = rect.height;
    }

    resizeCanvas();
    window.addEventListener('resize', resizeCanvas);

    const observer = new ResizeObserver(() => resizeCanvas());
    observer.observe(host);

    const particles = [];
    const particleCount = 45;

    class Particle {
        constructor() {
            this.reset();
        }

        reset() {
            this.x = Math.random() * canvas.width;
            this.y = Math.random() * canvas.height + canvas.height;
            this.size = Math.random() * 2 + 1;
            this.speedY = -(Math.random() * 0.8 + 0.2);
            this.speedX = (Math.random() - 0.5) * 0.3;
            this.opacity = Math.random() * 0.5 + 0.1;
            this.color = Math.random() > 0.5 ? '129, 140, 248' : '167, 139, 250';
        }

        update() {
            this.y += this.speedY;
            this.x += this.speedX;
            if (this.y < 0) {
                this.reset();
            }
        }

        draw() {
            ctx.beginPath();
            ctx.arc(this.x, this.y, this.size, 0, Math.PI * 2);
            ctx.fillStyle = `rgba(${this.color}, ${this.opacity})`;
            ctx.fill();
        }
    }

    for (let i = 0; i < particleCount; i++) {
        particles.push(new Particle());
        particles[i].y = Math.random() * canvas.height;
    }

    function animate() {
        ctx.clearRect(0, 0, canvas.width, canvas.height);

        const grad = ctx.createLinearGradient(0, 0, canvas.width, canvas.height);
        grad.addColorStop(0, 'rgba(37, 99, 235, 0.08)');
        grad.addColorStop(1, 'rgba(15, 118, 110, 0.07)');

        ctx.fillStyle = grad;
        ctx.fillRect(0, 0, canvas.width, canvas.height);

        ctx.strokeStyle = 'rgba(100, 116, 139, 0.12)';
        ctx.lineWidth = 1;

        for (let x = 48; x < canvas.width; x += 48) {
            ctx.beginPath();
            ctx.moveTo(x, 0);
            ctx.lineTo(x, canvas.height);
            ctx.stroke();
        }

        for (let y = 48; y < canvas.height; y += 48) {
            ctx.beginPath();
            ctx.moveTo(0, y);
            ctx.lineTo(canvas.width, y);
            ctx.stroke();
        }

        ctx.strokeStyle = 'rgba(37, 99, 235, 0.28)';
        ctx.lineWidth = 2;
        ctx.beginPath();
        ctx.moveTo(canvas.width * 0.08, canvas.height * 0.68);
        ctx.bezierCurveTo(
            canvas.width * 0.28,
            canvas.height * 0.28,
            canvas.width * 0.56,
            canvas.height * 0.78,
            canvas.width * 0.9,
            canvas.height * 0.34
        );
        ctx.stroke();

        particles.forEach((particle) => {
            particle.update();
            particle.draw();
        });

        requestAnimationFrame(animate);
    }

    animate();
})();
