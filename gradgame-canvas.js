(() => {
    const canvas = document.getElementById('canvas-new');
    const ctx = canvas.getContext('2d');
    const card = document.getElementById('session-new');

    function resizeCanvas() {
        const rect = card.getBoundingClientRect();
        canvas.width = rect.width;
        canvas.height = rect.height;
    }

    resizeCanvas();
    window.addEventListener('resize', resizeCanvas);

    const observer = new ResizeObserver(() => resizeCanvas());
    observer.observe(card);

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

        let w;
        let h;
        const targetRatio = 4 / 3;
        const canvasRatio = canvas.width / canvas.height;

        if (canvasRatio > targetRatio) {
            h = canvas.height;
            w = h * targetRatio;
        } else {
            w = canvas.width;
            h = w / targetRatio;
        }

        const x = (canvas.width - w) / 2;
        const y = (canvas.height - h) / 2;

        const grad = ctx.createLinearGradient(x, y, x + w, y + h);
        grad.addColorStop(0, 'rgba(99, 102, 241, 0.07)');
        grad.addColorStop(1, 'rgba(139, 92, 246, 0.07)');

        ctx.fillStyle = grad;
        ctx.fillRect(x, y, w, h);

        ctx.strokeStyle = 'rgba(99, 102, 241, 0.2)';
        ctx.lineWidth = 1.5;
        ctx.strokeRect(x, y, w, h);

        particles.forEach((particle) => {
            particle.update();
            particle.draw();
        });

        requestAnimationFrame(animate);
    }

    animate();
})();
